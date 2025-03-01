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

#if canImport(Darwin)
import Darwin
public import MachO
#endif

#if canImport(Darwin.ar)
import Darwin.ar
#endif

#if canImport(System)
import System
#else
import SystemPackage
#endif

public import struct Foundation.CharacterSet
public import class Foundation.FileManager
public import class Foundation.FileHandle
public import struct Foundation.Data
public import struct Foundation.UUID

public enum SwiftABIVersion: Equatable, Hashable, Sendable {
    /// For compatibility, we still need to deal with the unstable ABI for Swift <5.
    case unstable(Int)

    /// All future version of Swift >= 5 will use a stable ABI.
    case stable(Int)
}

// MARK: - LC_COMMANDS

public protocol PlatformInfoLookup {
    func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)?
}

/// A mechanism to get MachO info needed to construct a BuildVersion.Platform with a SupportedTargets entry from SDKSettings.
public protocol PlatformInfoProvider {
    /// Platform name
    var name: String { get }

    /// The target vendor to be passed in the target triple to LLVM-based tools for this variant.
    var llvmTargetTripleVendor: String? { get }

    /// The target system to be passed in the target triple to LLVM-based tools for this variant.  This is typically a platform name.
    var llvmTargetTripleSys: String? { get }

    /// The target environment to be passed in the target triple to LLVM-based tools for this variant.  This is the 'suffix' which comes after the three main components.
    var llvmTargetTripleEnvironment: String? { get }

    /// The build version platform ID for this variant.  Different platforms have different integers associated with them.
    var buildVersionPlatformID: Int? { get }

    /// The platform family name this SDK variant targets
    var platformFamilyName: String? { get }

    /// The TARGET_OS or other macro name used for diagnostics
    var targetOSMacroName: String? { get }

    /// Default deployment target version
    var defaultDeploymentTarget: Version? { get }

    /// _DEPLOYMENT_TARGET setting name
    var deploymentTargetSettingName: String? { get }
}

/// Abstraction over an `LC_BUILD_VERSION` or traditional `LC_VERSION_MIN_*` command.
public struct BuildVersion: Equatable, Hashable, Sendable {
    /// Enumerates platforms as defined by dyld.
    ///
    public struct Platform: RawRepresentable, Equatable, Hashable, Serializable, Sendable {
        public typealias RawValue = UInt32

        public static let macOS = Self(platformID: 1)
        public static let iOS = Self(platformID: 2)
        public static let tvOS = Self(platformID: 3)
        public static let watchOS = Self(platformID: 4)

        public static let macCatalyst = Self(platformID: 6)

        public static let iOSSimulator = Self(platformID: 7)
        public static let tvOSSimulator = Self(platformID: 8)
        public static let watchOSSimulator = Self(platformID: 9)

        public static let driverKit = Self(platformID: 10)

        public static let xrOS = Self(platformID: 11)
        public static let xrOSSimulator = Self(platformID: 12)

        public init?(rawValue: RawValue) {
            self.rawValue = rawValue
        }

        /// The integral values associated with each platform correspond to the constant value used to identify the platform in the `platform` field of an `LC_BUILD_VERSION` load command in a Mach-O file.
        public init(platformID: RawValue) {
            self.rawValue = platformID
        }

        /// Look up rawValue, which is the `platform` field of an `LC_BUILD_VERSION` load command in a Mach-O file.
        public let rawValue: RawValue

        /// Returns a suitable display name for the platform.
        ///
        /// These values are not guaranteed to be stable over time.
        public func displayName(infoLookup: any PlatformInfoLookup) -> String {
            switch self {
            case .macOS:
                return "macOS"
            case .macCatalyst:
                return "Mac Catalyst"
            case .iOS:
                return "iOS"
            case .iOSSimulator:
                return "iOS Simulator"
            case .tvOS:
                return "tvOS"
            case .tvOSSimulator:
                return "tvOS Simulator"
            case .watchOS:
                return "watchOS"
            case .watchOSSimulator:
                return "watchOS Simulator"
            case .driverKit:
                return "DriverKit"
            case .xrOS:
                return "visionOS"
            case .xrOSSimulator:
                return "visionOS Simulator"
            default:
                guard let name = infoLookup.lookupPlatformInfo(platform: self)?.name else {
                    return "Platform(\(rawValue))"
                }
                return name
            }
        }
    }

    /// The platform the given build version represents.
    public let platform: Platform

    /// The minimum OS version supported.
    public let minOSVersion: Version

    /// The SDK version that is targeted.
    public let sdkVersion: Version
}

extension BuildVersion.Platform {
    /// Initializes a build version platform from the platform and environment fields of an LLVM target triple.
    public init?(platform: String, environment: String?) {
        switch (platform, environment?.nilIfEmpty) {
        case ("macos", .none): self = .macOS
        case ("ios", "macabi"): self = .macCatalyst

        case ("ios", .none): self = .iOS
        case ("tvos", .none): self = .tvOS
        case ("watchos", .none): self = .watchOS
        case ("driverkit", .none): self = .driverKit
        case ("xros", .none): self = .xrOS

        case ("ios", "simulator"): self = .iOSSimulator
        case ("tvos", "simulator"): self = .tvOSSimulator
        case ("watchos", "simulator"): self = .watchOSSimulator
        case ("xros", "simulator"): self = .xrOSSimulator

        default: return nil
        }
    }
}

extension Set where Element == BuildVersion.Platform {
    public func displayName(infoLookup: any PlatformInfoLookup) -> String {
        switch count {
        case 0:
            // ld64 refers to Mach-O files with no build version commands as "freestanding", so we do too.
            return "freestanding"
        case 1:
            return self[startIndex].displayName(infoLookup: infoLookup)
        case 2 where self == [.macOS, .macCatalyst]:
            return "macOS (zippered)"
        default:
            // Multiple load commands (except the zippered case above) is defined as an invalid Mach-O, but historically many developers have used `lipo` to form "universal" static libraries for device and simulator platforms, and this is very common so make sure to show a good diagnostic for it.
            return sorted(by: \.rawValue).map { $0.displayName(infoLookup: infoLookup) }.joined(separator: " + ")
        }
    }
}

// MARK: Reading Binary Data

/// A protocol for all binary data that can be read from.
public protocol BinaryDataType {
    init()
}

/// Provides a protocol for working with binary data that can be read from.
public protocol BinaryData {
    /// Reads the binary data at the given offset.
    func read<T: BinaryDataType>(from offset: Int) throws -> T

    /// Returns the size, in bytes, of the data.
    var size: Int { get }
}

/// Provides a protocol that guarantees callers are able to view binary data without modifying any of the cursor locations of a `BinaryReader`.
public protocol BinaryReaderView {
    /// Reads the data at the given cursor location in the binary data.
    func peek<T: BinaryDataType>() throws -> T

    /// Reads the data at the given offset into the binary data.
    func peek<T: BinaryDataType>(offset: Int) throws -> T
}

public final class BinaryReader: BinaryReaderView {
    /// Marks the starting location and the current offset into the binary data.
    public struct Cursor: Sendable {
        /// The starting location to read from in the binary data.
        public let startingOffset: UnsafeRawBufferPointer.Index

        /// The current offset being read in the binary data.
        public let offset: UnsafeRawBufferPointer.Index
    }

    /// The binary data to read from.
    public let data: any BinaryData

    /// The size of the data to read, if specified.
    public let size: Int

    /// A stackable position within the binary data stream to be read from.
    private var cursors: [Cursor] = []

    /// The location in the data stream to treat at the 0-th position.
    private var startingOffset: Int

    /// Retrieves the effective size of the object, based on where the initial offset starts.
    private var effectiveSize: Int {
        return startingOffset + size
    }

    /// Returns true if the reader is currently at the EOF marker.
    public var eof: Bool {
        return offset >= effectiveSize
    }

    /// The current cursor information.
    public var cursor: Cursor {
        guard let current = cursors.last else {
            fatalError("There are no cursors presently on the stack to retrieve.")
        }
        return current
    }

    /// The current, absolute position within the binary data being read from.
    public var offset: UnsafeRawBufferPointer.Index {
        return cursor.startingOffset + cursor.offset
    }

    convenience public init(data: any BinaryData) {
        self.init(data: data, startingAt: 0)
    }

    /// A convenience initializer to allow copying of readers.
    convenience public init(other: BinaryReader) {
        self.init(data: other.data, startingAt: other.offset, size: other.size)
    }

    /// Initializes a new reader based on the binary data. If the `size` is not given, then the `size` from the given `data` will be used.
    public init(data: any BinaryData, startingAt: Int, size: Int? = nil) {
        self.data = data
        self.startingOffset = startingAt
        self.cursors.append(Cursor(startingOffset: startingAt, offset: 0))
        self.size = size ?? data.size
    }

    deinit {
        assert(cursors.count == 1, "peek() called without a corresponding pop() (active cursors: \(cursors.count))")
    }

    /// Reads the data at the current offset into the binary data. This does **not** change the current cursor information.
    public func peek<T: BinaryDataType>() throws -> T {
        return try peek(offset: 0)
    }

    /// Reads the data offset by the current offset into the binary data. This does **not** change the current cursor information.
    public func peek<T: BinaryDataType>(offset: Int) throws -> T {
        guard self.offset + offset + MemoryLayout<T>.size <= effectiveSize else {
            throw BinaryReaderError.invalidPeek(startingAt: self.offset, offsetBy: offset, type: T.self, typeSize: MemoryLayout<T>.size, dataSize: effectiveSize)
        }

        return try data.read(from: self.offset + offset)
    }

    /// Moves the current offset into the binary data by the number of specified bytes.
    @discardableResult
    public func seek(by numberOfBytes: Int) throws -> BinaryReader {
        let newOffset = offset + numberOfBytes
        guard newOffset >= cursor.startingOffset && newOffset <= effectiveSize else {
            throw BinaryReaderError.invalidSeek(cursor: cursor, numberOfBytes: numberOfBytes)
        }

        cursors[cursors.count - 1] = Cursor(startingOffset: cursor.startingOffset, offset: cursor.offset + numberOfBytes)
        return self
    }

    /// Moves the current offset into the binary data to the specified byte offset.
    @discardableResult
    public func seek(to offset: Int) throws -> BinaryReader {
        let newOffset = cursor.startingOffset + offset
        guard offset >= cursor.startingOffset && newOffset <= effectiveSize else {
            throw BinaryReaderError.invalidSeek(cursor: cursor, numberOfBytes: newOffset)
        }

        cursors[cursors.count - 1] = Cursor(startingOffset: cursor.startingOffset, offset: newOffset)
        return self
    }

    /// Reads the binary data at the current location, incrementing the cursor position.
    public func read<T: BinaryDataType>() throws -> T {
        let data: T = try peek()
        try seek(by: MemoryLayout<T>.size)
        return data
    }

    /// Reads the number of bytes at the current location, incrementing the cursor position.
    public func read(count: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<count {
            bytes.append(try read())
        }
        return bytes
    }

    /// This allows readers to maintain a parsing context, pushing the current cursor information onto a stack. This uses the current offset as the new starting offset.
    @discardableResult
    public func push() -> BinaryReader {
        cursors.append(Cursor(startingOffset: cursor.offset + cursor.startingOffset, offset: 0))
        return self
    }

    /// This pops the the current cursor information from the stack, returning the reader to its previous state.
    @discardableResult
    public func pop() -> BinaryReader {
        precondition(cursors.count > 1)
        cursors.removeLast()
        return self
    }
}

@available(*, unavailable)
extension BinaryReader: Sendable { }

extension ByteString: BinaryData {

    public func read<T: BinaryDataType>(from offset: Int) throws -> T {
        assert(0 <= offset)
        guard offset + MemoryLayout<T>.size <= size else {
            throw BinaryReaderError.invalidRead(startingAt: offset, type: T.self, typeSize: MemoryLayout<T>.size, dataSize: size)
        }

        var value = T()
        try withUnsafeMutableBytes(of: &value, { (to: UnsafeMutableRawBufferPointer) throws -> Void in
            self.bytes.withUnsafeBytes { from in
                let _ = memcpy(to.baseAddress!, from.baseAddress! + offset, MemoryLayout<T>.size)
            }
        })
        return value
    }

    public var size: Int {
        return bytes.count
    }
}

extension FileHandle: BinaryData {

    public func read<T: BinaryDataType>(from offset: Int) throws -> T {
        assert(0 <= offset)
        guard offset + MemoryLayout<T>.size <= size else {
            throw BinaryReaderError.invalidRead(startingAt: offset, type: T.self, typeSize: MemoryLayout<T>.size, dataSize: size)
        }

        var value = T()
        try withUnsafeMutableBytes(of: &value) { (ptr: UnsafeMutableRawBufferPointer) throws -> Void in
            let currentOffset = try self.offset()
            let result = Result {
                try self.seek(toOffset: UInt64(offset))
                return try self.read(upToCount: MemoryLayout<T>.size) ?? Data()
            }
            try self.seek(toOffset: currentOffset)
            let data = try result.get()
            ptr.copyBytes(from: data)
            let bytes = data.count
            assert(bytes == MemoryLayout<T>.size)
        }
        return value
    }

    public var size: Int {
        #if os(Windows)
        var info = LARGE_INTEGER()
        guard GetFileSizeEx(_handle, &info) else {
            return Int.max
        }
        return Int(info.QuadPart)
        #else
        var info = stat()
        guard fstat(self.fileDescriptor, &info) != -1 else {
            return Int.max
        }
        return Int(info.st_size)
        #endif
    }
}


/// Expresses an error when reading a binary file.
public enum BinaryReaderError: Error, CustomStringConvertible {
    /// Expresses an error which indicates the file does not appear to be a Mach-O or static archive at all, based on its magic.
    case unrecognizedFileType(magicWord1: UInt32, magicWord2: UInt32?)

    /// Expresses an error while attempting to parse the binary representation, e.g. missing expected magic bytes, unexpected EOF.
    case parseError(String)

    /// Expresses an out-of-range error while attempting to peek a structure in the binary data.
    case invalidPeek(startingAt: Int, offsetBy: Int, type: Any.Type, typeSize: Int, dataSize: Int)

    /// Expresses an out-of-range error while attempting to read a structure from the binary data.
    case invalidRead(startingAt: Int, type: Any.Type, typeSize: Int, dataSize: Int)

    /// Expresses an error while attempting to seek within the binary data.
    case invalidSeek(cursor: BinaryReader.Cursor, numberOfBytes: Int)

    /// Output a friendly description of the error.
    public var description: String {
        switch self {
        case .unrecognizedFileType(let magic1, let magic2):
            return "Unknown header: 0x\(String(magic1, radix: 16))" + (magic2.map { String($0, radix: 16) } ?? "")
        case .parseError(let s):
            return s
        case .invalidPeek(let start, let offset, let type, let typeSize, let size):
            return "Invalid read request. startingAt: \(start), offsetBy: \(offset), typeSize: \(typeSize) (\(type)), dataSize: \(size)"
        case .invalidRead(let offset, let type, let typeSize, let size):
            return "Attempting to read past the size of the binary data. startingAt: \(offset), typeSize: \(typeSize) (\(type)), dataSize: \(size)"
        case .invalidSeek(let cursor, let numberOfBytes):
            return "Invalid seek from \(cursor) by \(numberOfBytes) byte(s)"
        }
    }
}

#if !canImport(Darwin)
fileprivate let FAT_MAGIC: UInt32 = 0xcafebabe
fileprivate let FAT_CIGAM: UInt32 = 0xbebafeca
fileprivate let FAT_MAGIC_64: UInt32 = 0xcafebabf
fileprivate let FAT_CIGAM_64: UInt32 = 0xbfbafeca
fileprivate let MH_MAGIC: UInt32 = 0xfeedface
fileprivate let MH_CIGAM: UInt32 = 0xcefaedfe
fileprivate let MH_MAGIC_64: UInt32 = 0xfeedfacf
fileprivate let MH_CIGAM_64: UInt32 = 0xcffaedfe
fileprivate let MH_OBJECT: UInt32 = 0x1
fileprivate let MH_EXECUTE: UInt32 = 0x2
fileprivate let MH_DYLIB: UInt32 = 0x6
fileprivate let MH_BUNDLE: UInt32 = 0x8
fileprivate let SYMDEF = "__.SYMDEF"
fileprivate let SYMDEF_SORTED = "__.SYMDEF SORTED"
fileprivate let SYMDEF_64 = "__.SYMDEF_64"
fileprivate let SYMDEF_64_SORTED = "__.SYMDEF_64 SORTED"
public typealias cpu_type_t = Int32
public typealias cpu_subtype_t = Int32
public typealias vm_prot_t = Int32
public let CPU_TYPE_ANY: Int32 = -1
#endif

// MARK: - Mach-O String Parsing

fileprivate let machOStringEncoding = String.Encoding.utf8


/// Some MachO strings are encoded in fixed size char arrays, e.g. `struct S { char[16] str; }`. These may contain a null terminator or use the full length of the array.
fileprivate func parseMachOFixedSizeString(_ bytes: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) throws -> String {
    var mutableBytes = bytes

    let resultOpt = withUnsafeBytes(of: &mutableBytes) { (ptr: UnsafeRawBufferPointer) -> String? in
        // `ptr` conforms to Collection and has a known count, so we won't read more than the size of the tuple.

        // `String(bytes:encoding:)` does not stop at nil terminators, so we need to shorten `ptr.count` if there's a nil terminator.
        let ptrEndingAtNil = ptr.prefix(upTo: ptr.firstIndex(of: 0) ?? ptr.count)

        return String(bytes: ptrEndingAtNil, encoding: machOStringEncoding)
    }

    guard let result = resultOpt else { throw BinaryReaderError.parseError("Failed to parse string: \(bytes)") }
    return result
}

/// Some MachO strings are encoded in char arrays with a known maximum size and always contain a null terminator.
fileprivate func parseMachONullTerminatedString(_ ptr: UnsafeRawBufferPointer) throws -> String {
    guard let nullIndex = ptr.firstIndex(of: 0) else { throw BinaryReaderError.parseError("Failed to parse string: no null in \(Array(ptr))") }
    guard let result = String(bytes: ptr.prefix(upTo: nullIndex), encoding: machOStringEncoding) else { throw BinaryReaderError.parseError("Failed to parse string: \(Array(ptr))") }
    return result
}

// MARK: - Mach-O wrappers

extension UInt8: BinaryDataType{}
extension UInt32: BinaryDataType{}

#if canImport(Darwin)

extension fat_header: BinaryDataType{}
extension mach_header: BinaryDataType{}
extension mach_header_64: BinaryDataType{}
extension fat_arch: BinaryDataType{}
extension fat_arch_64: BinaryDataType{}
extension load_command: BinaryDataType{}
extension dylib_command: BinaryDataType{}
extension uuid_command: BinaryDataType{}
extension segment_command: BinaryDataType{}
extension segment_command_64: BinaryDataType{}
extension section: BinaryDataType{}
extension section_64: BinaryDataType{}
extension build_version_command: BinaryDataType{}
extension version_min_command: BinaryDataType{}
extension rpath_command: BinaryDataType{}

#if DONT_HAVE_LC_ATOM_INFO || SWIFT_PACKAGE
fileprivate let LC_ATOM_INFO = (0x36)
#endif

#endif

#if canImport(Darwin.ar)

extension ar_hdr: BinaryDataType{}

#endif

// MARK: - Mach-O byte swapping helpers

fileprivate protocol ByteSwappable {
    var byteSwapped: Self {get}
}

extension Int16: ByteSwappable {}
extension UInt16: ByteSwappable {}
extension Int32: ByteSwappable {}
extension UInt32: ByteSwappable {}
extension Int64: ByteSwappable {}
extension UInt64: ByteSwappable {}

fileprivate func shouldSwap(magic: UInt32) -> Bool {
    return magic == MH_CIGAM || magic == MH_CIGAM_64 || magic == FAT_CIGAM || magic == FAT_CIGAM_64
}

extension ByteSwappable {
    func byteSwappedIfNeeded(_ swap: Bool) -> Self {
        return swap ? self.byteSwapped : self
    }
}

// MARK: - Extensions of the mach headers.

/// Provides a protocol to conform the 32 and 64 bit Mach-O fat headers together.
public protocol MachOFatHeader {
    // These are direct mappings of the fat_arch.
    var cputype: cpu_type_t { get }
    var cpusubtype: cpu_subtype_t { get }
    var align: UInt32 { get }

    // fat_arch and fat_arch_64 have different field sizes; we need an indirection

    func offset(byteSwappedIfNeeded swap: Bool) -> UInt64
    func size(byteSwappedIfNeeded swap: Bool) -> UInt64

    // The reserved field is intentionally left missing from here for fat_arch_64.

    var structSize: Int { get }
}

#if canImport(Darwin)

extension fat_arch: MachOFatHeader {
    public func offset(byteSwappedIfNeeded swap: Bool) -> UInt64 {
        return UInt64(offset.byteSwappedIfNeeded(swap))
    }

    public func size(byteSwappedIfNeeded swap: Bool) -> UInt64 {
        return UInt64(size.byteSwappedIfNeeded(swap))
    }

    /// Returns the size, in bytes, of the `fat_arch` struct.
    public var structSize: Int {
        return MemoryLayout<fat_arch>.size
    }
}

extension fat_arch_64: MachOFatHeader {
    public func offset(byteSwappedIfNeeded swap: Bool) -> UInt64 {
        return offset.byteSwappedIfNeeded(swap)
    }

    public func size(byteSwappedIfNeeded swap: Bool) -> UInt64 {
        return size.byteSwappedIfNeeded(swap)
    }

    /// Returns the size, in bytes, of the `fat_arch_64` struct.
    public var structSize: Int {
        return MemoryLayout<fat_arch_64>.size
    }
}

#endif

/// Provides a protocol to conform the 32 and 64 bit Mach-O headers together.
public protocol MachOHeader {
    // These are direct mappings of the mach_header.
    var magic: UInt32 { get }
    var cputype: cpu_type_t  {get }
    var cpusubtype: cpu_subtype_t { get }
    var filetype: UInt32 { get }
    var ncmds: UInt32 { get }
    var sizeofcmds: UInt32 { get }
    var flags: UInt32 { get }

    // The reserved field is intentionally left missing from here for mach_header_64.

    var structSize: Int { get }
}

#if canImport(Darwin)

extension mach_header: MachOHeader {
    /// Returns the size, in bytes, of the `mach_header` struct.
    public var structSize: Int {
        return MemoryLayout<mach_header>.size
    }
}
extension mach_header_64: MachOHeader {
    /// Returns the size, in bytes, of the `mach_header_64` struct.
    public var structSize: Int {
        return MemoryLayout<mach_header_64>.size
    }
}

#endif

// MARK: -

public protocol MachOSegmentLoadCommand {
    var cmd: UInt32 {get}
    var cmdsize: UInt32 {get}
    var segname: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8) {get}

    var vmaddr64: UInt64 {get}
    var vmsize64: UInt64 {get}
    var fileoff64: UInt64 {get}
    var filesize64: UInt64 {get}

    var maxprot: vm_prot_t {get}
    var initprot: vm_prot_t {get}
    var nsects: UInt32 {get}
    var flags: UInt32 {get}

    var structSize: Int {get}
}

public extension MachOSegmentLoadCommand {
    func segname() throws -> String {
        return try parseMachOFixedSizeString(self.segname)
    }
}

#if canImport(Darwin)

extension segment_command: MachOSegmentLoadCommand {
    public var vmaddr64: UInt64 { return UInt64(self.vmaddr) }
    public var vmsize64: UInt64 { return UInt64(self.vmsize) }
    public var fileoff64: UInt64 { return UInt64(self.fileoff) }
    public var filesize64: UInt64 { return UInt64(self.filesize) }

    public var structSize: Int {
        return MemoryLayout<segment_command>.size
    }
}

extension segment_command_64: MachOSegmentLoadCommand {
    public var vmaddr64: UInt64 { return self.vmaddr }
    public var vmsize64: UInt64 { return self.vmsize }
    public var fileoff64: UInt64 { return self.fileoff }
    public var filesize64: UInt64 { return self.filesize }

    public var structSize: Int {
        return MemoryLayout<segment_command_64>.size
    }
}

#endif

// MARK: - Mach-O section information

public protocol MachOSection {
    var sectname: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8) {get}
    var segname: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8) {get}
    var addr64: UInt64 {get}
    var size64: UInt64 {get}
    var offset: UInt32 {get}
    var align: UInt32 {get}
    var reloff: UInt32 {get}
    var nreloc: UInt32 {get}
    var flags: UInt32 {get}
}

extension MachOSection {
    func sectname() throws -> String {
        return try parseMachOFixedSizeString(self.sectname)
    }

    func segname() throws -> String {
        return try parseMachOFixedSizeString(self.segname)
    }
}

#if canImport(Darwin)

extension section: MachOSection {
    public var addr64: UInt64 {
        return UInt64(self.addr)
    }

    public var size64: UInt64 {
        return UInt64(self.size)
    }
}

extension section_64: MachOSection {
    public var addr64: UInt64 {
        return self.addr
    }

    public var size64: UInt64 {
        return self.size
    }
}

#endif

/// A representation of a Mach-O file. This type supports both thin and fat Mach-O files. In addition, if static archives are encountered, those will be unpacked here as well.
public final class MachO {

    /// This is a bit hacky, but we need to communicate that the header found is a static archive, to then try and reparse the Mach-O appropriately.
    fileprivate enum MachOError: Error {
        case staticArchive
    }

    /// The type of Mach-O data that is contained with the file.
    public enum MachOType: Sendable {
        /// Only a single architecture is included.
        case thin

        /// Multiple architectures are contained within the Mach-O file.
        case fat(magic: UInt32)

        /// The Mach-O file contains a thin-archive header.
        case archive

        /// Tries to initialize the Mach-O type based on the given binary representation.
        init(reader: any BinaryReaderView) throws {
            let magic: UInt32 = try reader.peek()

            switch magic {
            case MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64:
                self = .thin

            case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
                self = .fat(magic: magic)

            case UInt32(bigEndian: StaticArchive.ARMAG1):
                let magic2: UInt32 = try reader.peek(offset: MemoryLayout<UInt32>.size)
                if magic2 == UInt32(bigEndian: StaticArchive.ARMAG2) {
                    self = .archive
                }
                else {
                    throw BinaryReaderError.unrecognizedFileType(magicWord1: magic, magicWord2: magic2)
                }

            default:
                throw BinaryReaderError.unrecognizedFileType(magicWord1: magic, magicWord2: nil)
            }
        }
    }

    public struct FileType: Sendable, Equatable, Hashable {
        public let rawValue: UInt32
        public static let object = FileType(rawValue: UInt32(MH_OBJECT))
        public static let dylib = FileType(rawValue: UInt32(MH_DYLIB))
        public static let execute = FileType(rawValue: UInt32(MH_EXECUTE))
        public static let bundle = FileType(rawValue: UInt32(MH_BUNDLE))
    }

    /// Whether or not the given file is a static archive or a dynamically linked Mach-O.
    public enum WrappedFileType: Sendable, Equatable, Hashable {
        case macho(FileType)
        case `static`
    }

    /// The raw bytes containing the Mach-O data.
    private var reader: BinaryReader

    /// The type of content held within the Mach-O file.
    public let machOType: MachOType

    /// Initializes a new `MachO` instance based on the given bytes.
    public init(reader: BinaryReader) throws {
        self.reader = reader
        self.machOType = try MachOType(reader: reader)
    }

    /// Convenience initializer for creating a `MachO` instance from a `BinaryData` instance.
    convenience public init(data: any BinaryData) throws {
        try self.init(reader: BinaryReader(data: data))
    }

    /// Returns an array of slices representing the Mach-O file contents.
    ///
    /// - seealso: Slice
    public func slices() throws -> [Slice] {
        return try slicesIncludingLinkage().slices
    }

    /// Returns an array of slices representing the Mach-O file contents and the overall linkage being used.
    ///
    /// - seealso: Slice
    public func slicesIncludingLinkage() throws -> (slices: [Slice], linkage: WrappedFileType)  {
        // Ensure that this is re-entrant and that no lasting state modification happens within this function.
        reader.push()
        defer { reader.pop() }

        switch machOType {
        case .thin:
            let slices = try [Slice(reader: BinaryReader(other: reader))]
            guard let linkage = Set(slices.map(\.linkFileType)).only else {
                throw BinaryReaderError.parseError("All the slices should have the same linkage fileType")
            }
            return (slices, linkage)
        case let .fat(magic):
            let archs: [any MachOFatHeader] = try .init(reader: reader)
            let swap = shouldSwap(magic: magic)
            do {
                let slices = try archs.compactMap { arch in
                    try Slice(reader: BinaryReader(data: reader.data, startingAt: Int(arch.offset(byteSwappedIfNeeded: swap)), size: Int(arch.size(byteSwappedIfNeeded: swap))))
                }
                guard let linkage = Set(slices.map(\.linkFileType)).only else {
                    throw BinaryReaderError.parseError("All the slices should have the same linkage fileType")
                }
                return (slices, linkage)
            } catch MachOError.staticArchive {
                // Since we've encountered a potential static archive, attempt to re-read it and implicitly unwrap its slices.
                let archive = try StaticArchive(reader: BinaryReader(data: reader.data, startingAt: 0))
                return (try archive.machOs().flatMap { try $0.slices() }, .static)
            }

        case .archive:
            let archive = try StaticArchive(reader: BinaryReader(other: reader))
            return (try archive.machOs().flatMap { try $0.slices() }, .static)
        }
    }

    /// If the root file is a fat Mach-O file, a slice will represent each
    /// contained thin Mach-O file, or each contained static archive file, which
    /// in turn each contains a series of Mach-O object files.
    ///
    /// If the root file is a thin Mach-O file, the `MachO` object will
    /// simply contain a single `Slice` representing the thin Mach-O file itself.
    public struct Slice {
        private let reader: BinaryReader
        private let header: Header

        init(reader: BinaryReader) throws {
            self.reader = reader
            self.header = try Header(reader: reader)
        }

        enum Header {
            init(reader: any BinaryReaderView) throws {
                let magic: UInt32 = try reader.peek()
                switch magic {
                #if canImport(Darwin)
                case MH_MAGIC, MH_CIGAM:
                    self = try .mach_header(reader.peek())

                case MH_MAGIC_64, MH_CIGAM_64:
                    self = try .mach_header_64(reader.peek())
                #else
                case MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64:
                    throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
                #endif

                case UInt32(bigEndian: StaticArchive.ARMAG1):
                    let magic2: UInt32 = try reader.peek(offset: MemoryLayout<UInt32>.size)
                    if magic2 == UInt32(bigEndian: StaticArchive.ARMAG2) {
                        throw MachOError.staticArchive
                    } else {
                        throw BinaryReaderError.parseError("Unknown header: 0x\(String(magic.bigEndian, radix: 16))\(String(magic2.bigEndian, radix: 16))")
                    }

                default:
                    throw BinaryReaderError.parseError("Unknown header: 0x\(String(magic.bigEndian, radix: 16))")
                }
            }

            #if canImport(Darwin)
            case mach_header(mach_header)
            case mach_header_64(mach_header_64)
            #endif
        }


        var headers: [(Slice, any MachOHeader)] {
            #if canImport(Darwin)
            switch self.header {
            case .mach_header(let x): return [(self, x)]
            case .mach_header_64(let x): return [(self, x)]
            }
            #else
            assertionFailure("not implemented")
            return []
            #endif
        }

        public var arch: String {
            precondition(headers.count <= 1, "invalid to call arch when there are multiple headers")

            #if canImport(Darwin)
            if let (_, header) = headers.only {
                if let name = Architecture.stringValue(cputype: header.cputype, cpusubtype: header.cpusubtype) {
                    return name
                }
            }
            #endif

            return "unknown"
        }

        public enum LinkageType: Sendable {
            case normal
            case lazy
            case weak
            case upward
            case reexport
        }

        /// Return the names and linkage types of all linked libraries.
        public func linkedLibraries() throws -> [(pathStr: String, linkageType: LinkageType)] {
            #if canImport(Darwin)
            return try loadCommands().compactMap { lc throws -> (String, LinkageType)? in
                let cmd: dylib_command
                let linkageType: LinkageType

                switch lc.value {
                case .loadDylib(let dl):
                    cmd = dl
                    linkageType = .normal

                case .lazyLoadDylib(let dl):
                    cmd = dl
                    linkageType = .lazy

                case .loadWeakDylib(let dl):
                    cmd = dl
                    linkageType = .weak

                case .upwardDylib(let dl):
                    cmd = dl
                    linkageType = .upward

                case .reexportDylib(let dl):
                    cmd = dl
                    linkageType = .reexport

                default:
                    return nil
                }

                let cmdSize = Int(cmd.cmdsize.byteSwappedIfNeeded(lc.swap))
                let nameOffset = Int(cmd.dylib.name.offset.byteSwappedIfNeeded(lc.swap))
                guard nameOffset <= cmdSize else { throw BinaryReaderError.parseError("Failed to parse dylib name: offset out of bounds") }

                let reader = BinaryReader(data: lc.reader.data, startingAt: lc.reader.offset + nameOffset)
                let bytes: [UInt8] = try reader.read(count: cmdSize)

                let pathStr = try bytes.withUnsafeBytes { ptr throws -> String in
                    return try parseMachONullTerminatedString(ptr)
                }
                return (pathStr, linkageType)
            }
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        /// Return the names of all linked libraries.
        public func linkedLibraryPaths() throws -> [String] {
            return try linkedLibraries().map { $0.pathStr }
        }

        public func installName() throws -> String? {
            #if canImport(Darwin)
            let installNames = try loadCommands().compactMap { (lc: LoadCommand) throws -> String? in
                switch lc.value {
                case let .idDylib(cmd):
                    let cmdSize = Int(cmd.cmdsize.byteSwappedIfNeeded(lc.swap))
                    let nameOffset = Int(cmd.dylib.name.offset.byteSwappedIfNeeded(lc.swap))
                    guard nameOffset <= cmdSize else { throw BinaryReaderError.parseError("Failed to parse dylib name: offset out of bounds") }

                    let reader = BinaryReader(data: lc.reader.data, startingAt: lc.reader.offset + nameOffset)
                    let bytes: [UInt8] = try reader.read(count: cmdSize)

                    return try bytes.withUnsafeBytes { ptr throws -> String in
                        return try parseMachONullTerminatedString(ptr)
                    }
                default:
                    return nil
                }
            }

            if installNames.count > 1 {
                throw BinaryReaderError.parseError("Encountered multiple LC_ID_DYLIB load commands")
            }

            return installNames.only
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        // rdar://92212555. Static binary is detected as dynamic instead of an object, causing it to get embedded into the framework
        // A simple fix is to create FileTypes 'object' and other valid, and check when providing slice linkage information.
        public var linkFileType: WrappedFileType {
            switch (header) {
#if canImport(Darwin)
            case .mach_header(let header):
                return .macho(FileType(rawValue: header.filetype))
            case .mach_header_64(let header):
                return .macho(FileType(rawValue: header.filetype))
#endif
            }
        }

        public func uuid() throws -> UUID? {
            #if canImport(Darwin)
            let uuids = try loadCommands().compactMap { (lc: LoadCommand) throws -> UUID? in
                switch lc.value {
                case .uuid(let ulc): return UUID(uuid: ulc.uuid)
                default: return nil
                }
            }

            guard !uuids.isEmpty else { return nil }
            guard uuids.count == 1 else { throw BinaryReaderError.parseError("Encountered multiple UUID load commands") }
            return uuids[0]
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        #if canImport(Darwin)
        public struct LoadCommand {
            let reader: BinaryReader
            let swap: Bool
            @_spi(Testing) public let base: load_command
            let value: ConcreteValue

            init(slice: Slice, reader: BinaryReader, swap: Bool) throws {
                self.reader = reader
                self.swap = swap

                reader.push()

                let base: load_command = try reader.peek()
                self.base = base
                self.value = try { () throws -> ConcreteValue in
                    switch base.cmd {
                    case UInt32(LC_ID_DYLIB):
                        return try .idDylib(reader.read())

                    case UInt32(LC_LOAD_DYLIB):
                        return try .loadDylib(reader.read())

                    case UInt32(LC_LAZY_LOAD_DYLIB):
                        return try .lazyLoadDylib(reader.read())

                    case UInt32(LC_LOAD_WEAK_DYLIB):
                        return try .loadWeakDylib(reader.read())

                    case UInt32(LC_LOAD_UPWARD_DYLIB):
                        return try .upwardDylib(reader.read())

                    case UInt32(LC_REEXPORT_DYLIB):
                        return try .reexportDylib(reader.read())

                    case UInt32(LC_UUID):
                        return try .uuid(reader.read())

                    case UInt32(LC_SEGMENT):
                        return try .segment(reader.read())

                    case UInt32(LC_SEGMENT_64):
                        return try .segment_64(reader.read())

                    case UInt32(LC_BUILD_VERSION):
                        return try .build_version(reader.read())

                    case UInt32(LC_VERSION_MIN_MACOSX),
                         UInt32(LC_VERSION_MIN_IPHONEOS),
                         UInt32(LC_VERSION_MIN_TVOS),
                         UInt32(LC_VERSION_MIN_WATCHOS):
                        return try .version_min(reader.read())

                    case UInt32(LC_RPATH):
                        return try .rpath(reader.read())

                    case UInt32(LC_ATOM_INFO):
                        // We are not yet parsing the contents of this command.
                        return .atom_info(base)

                    default:
                        return .other(base)
                    }
                }()

                reader.pop()
            }

            enum ConcreteValue {
                case idDylib(dylib_command)
                case loadDylib(dylib_command)
                case lazyLoadDylib(dylib_command)
                case loadWeakDylib(dylib_command)
                case upwardDylib(dylib_command)
                case reexportDylib(dylib_command)
                case uuid(uuid_command)
                case segment(segment_command)
                case segment_64(segment_command_64)
                case build_version(build_version_command)
                case version_min(version_min_command)
                case rpath(rpath_command)
                case atom_info(load_command)

                case other(load_command)
            }
        }

        /// The load commands of the Mach-O file, or in the case of a static
        /// archive, the combined load commands of all of the contained Mach-O
        /// object files.
        public func loadCommands() throws -> [LoadCommand] {
            return try headers.map { (slice, header) in
                let swap = shouldSwap(magic: header.magic)
                let ncmds = Int(header.ncmds.byteSwappedIfNeeded(swap))
                var offset = header.structSize

                return try (0 ..< ncmds).map { index throws -> LoadCommand in
                    let loadCommand = try LoadCommand(slice: slice, reader: BinaryReader(data: reader.data, startingAt: reader.offset + offset), swap: swap)
                    let size = loadCommand.base.cmdsize.byteSwappedIfNeeded(swap)
                    offset += Int(size)
                    return loadCommand
                }
            }.reduce([], { $0 + $1 })
        }
        #endif

        public func rpaths() throws -> [String] {
            #if canImport(Darwin)
            return try self.loadCommands().compactMap({ (lc: LoadCommand) -> String? in
                guard case let .rpath(rpath) = lc.value else {
                    return nil
                }

                lc.reader.push()
                defer { lc.reader.pop() }

                try lc.reader.seek(by: Int(rpath.path.offset))
                var data = try lc.reader.read(count: Int(rpath.cmdsize - rpath.path.offset))

                // Clean the rpath from 0-padding bytes.
                while data.last == 0 {
                    data.removeLast()
                }

                return String(bytes: data, encoding: .utf8)
            })
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        #if canImport(Darwin)
        public struct Segment {
            let loadCommand: LoadCommand
            let value: ConcreteValue

            init(loadCommand: LoadCommand, value: ConcreteValue) {
                self.loadCommand = loadCommand
                self.value = value
            }

            enum ConcreteValue {
                case segment(segment_command)
                case segment_64(segment_command_64)

                var segment: any MachOSegmentLoadCommand {
                    switch self {
                    case .segment(let s): return s
                    case .segment_64(let s): return s
                    }
                }
            }

            @_spi(Testing) public enum Section: Sendable {
                case section(section)
                case section_64(section_64)

                var section: any MachOSection {
                    switch self {
                    case .section(let s): return s
                    case .section_64(let s): return s
                    }
                }
            }

            @_spi(Testing) public func sections() throws -> [Section] {
                let value = self.value
                let nsects = Int(value.segment.nsects.byteSwappedIfNeeded(loadCommand.swap))
                let offset = value.segment.structSize

                let reader = BinaryReader(data: loadCommand.reader.data, startingAt: loadCommand.reader.offset + offset)

                func readSection() throws -> Section {
                    switch value {
                    case .segment:
                        return try .section(reader.read())

                    case .segment_64:
                        return try .section_64(reader.read())
                    }
                }

                return try (0 ..< nsects).map { _ in
                    return try readSection()
                }
            }
        }

        public func segments() throws -> [Segment] {
            return try self.loadCommands().compactMap { (lc: LoadCommand) -> Segment? in
                switch lc.value {
                case .segment(let sc):
                    return Segment(loadCommand: lc, value: .segment(sc))

                case .segment_64(let sc):
                    return Segment(loadCommand: lc, value: .segment_64(sc))

                default: return nil
                }
            }
        }
        #endif

        public func buildVersions() throws -> [BuildVersion] {
            #if canImport(Darwin)
            return try loadCommands().compactMap { loadCommand in
                switch loadCommand.value {
                case .build_version(let cmd):
                    guard let platform = BuildVersion.Platform(rawValue: cmd.platform) else {
                        throw BinaryReaderError.parseError("Unrecognized value '\(cmd.platform)' for LC_BUILD_VERSION platform field")
                    }
                    return BuildVersion(platform: platform, minOSVersion: Version(machOVersion: cmd.minos), sdkVersion: Version(machOVersion: cmd.sdk))
                case .version_min(let cmd):
                    guard let (_, header) = headers.first else { throw BinaryReaderError.parseError("much call buildVersions with valid headers") }

                    let platform: BuildVersion.Platform
                    switch Int32(cmd.cmd) {
                    case LC_VERSION_MIN_MACOSX:
                        platform = .macOS
                    case LC_VERSION_MIN_IPHONEOS:
                        platform = [CPU_TYPE_X86, CPU_TYPE_X86_64].contains(header.cputype) ? .iOSSimulator : .iOS
                    case LC_VERSION_MIN_TVOS:
                        platform = [CPU_TYPE_X86, CPU_TYPE_X86_64].contains(header.cputype) ? .tvOSSimulator : .tvOS
                    case LC_VERSION_MIN_WATCHOS:
                        platform = [CPU_TYPE_X86, CPU_TYPE_X86_64].contains(header.cputype) ? .watchOSSimulator : .watchOS
                    default:
                        throw BinaryReaderError.parseError("Unrecognized LC_VERSION_MIN_* command (\(cmd.cmd))")
                    }
                    return BuildVersion(platform: platform, minOSVersion: Version(machOVersion: cmd.version), sdkVersion: Version(machOVersion: cmd.sdk))
                default:
                    return nil
                }
            }
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        public func containsAtomInfo() throws -> Bool {
            #if canImport(Darwin)
            return try loadCommands().contains(where: { loadCommand in
                switch loadCommand.value {
                case .atom_info(_):
                    return true
                default:
                    return false
                }
            })
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        #if canImport(Darwin)
        private func sectionsMatching(_ segmentSectionNames: [(segmentName: String, sectionName: String)]) throws -> [(Bool, MachO.Slice.Segment.Section)] {
            let isObject = self.headers.allSatisfy { (slice, header) in return header.filetype == MH_OBJECT }
            return try self.segments().filter { (segment: Segment) throws -> Bool in
                // If it's an object file, all the sections are part of a single segment with no name.
                if isObject {
                    return try segment.value.segment.segname().isEmpty
                } else {
                    return try segmentSectionNames.map{$0.segmentName}.contains(segment.value.segment.segname())
                }
            }
            .flatMap{ (segment: Segment) throws -> [(Bool, Segment.Section)] in
                return try segment.sections().filter { (section: Segment.Section) throws -> Bool in
                    let s = section.section
                    return try segmentSectionNames.contains { try $0.segmentName == s.segname() && $0.sectionName == s.sectname() }
                }.map { (segment.loadCommand.swap, $0) }
            }
        }
        #endif

        public func swiftABIVersion() throws -> SwiftABIVersion? {
            #if canImport(Darwin)
            // The Swift ABI version is in the ObjC image info section, which might be in either the __DATA, __DATA_CONST, or the __OBJC segment.
            let segmentSectionNames = [
                ("__DATA", "__objc_imageinfo"),
                ("__DATA_CONST", "__objc_imageinfo"),
                ("__OBJC", "__image_info"),
                ]

            let sections = try sectionsMatching(segmentSectionNames)

            // We expect a single ObjC image info section, otherwise we bail
            guard !sections.isEmpty else { return nil }
            guard sections.count == 1 else { throw BinaryReaderError.parseError("Found multiple ObjC image info sections") }
            let (swap, section) = sections[0]

            reader.push()
            defer { reader.pop() }

            // Read objc_image_info struct
            let objcInfo = try reader.seek(by: Int(section.section.offset.byteSwappedIfNeeded(swap)))
            let flags = (try objcInfo.seek(by: 4).read() as UInt32).byteSwappedIfNeeded(swap)

            // FIXME: We should be using a shared definition for this.
            let swiftVersion = (flags >> 8) & 0xff
            guard swiftVersion != 0 else { return nil }

            // NOTE: Swift 5.0 uses 7 as the ABI value. This is the first Swift with a stable ABI.

            let vers = Int(swiftVersion)
            return vers < 7 ? .unstable(vers) : .stable(vers)
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        public func simulatedEntitlements() throws -> PropertyListItem? {
            #if canImport(Darwin)
            let sections = try sectionsMatching([("__TEXT", "__entitlements")])

            // We expect a single section, otherwise we bail
            guard !sections.isEmpty else { return nil }
            guard sections.count == 1 else { throw BinaryReaderError.parseError("Found multiple __entitlements sections") }
            let (swap, section) = sections[0]

            reader.push()
            defer { reader.pop() }

            let sectionReader = try reader.seek(by: Int(section.section.offset.byteSwappedIfNeeded(swap)))
            return try PropertyList.fromBytes(sectionReader.read(count: Int(section.section.size64)))
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        public func simulatedDEREntitlements() throws -> [UInt8]? {
            #if canImport(Darwin)
            let sections = try sectionsMatching([("__TEXT", "__ents_der")])

            // We expect a single section, otherwise we bail
            guard !sections.isEmpty else { return nil }
            guard sections.count == 1 else { throw BinaryReaderError.parseError("Found multiple __ents_der sections") }
            let (swap, section) = sections[0]

            reader.push()
            defer { reader.pop() }

            let sectionReader = try reader.seek(by: Int(section.section.offset.byteSwappedIfNeeded(swap)))
            return try sectionReader.read(count: Int(section.section.size64))
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }

        public func remarks() throws -> Data? {
            #if canImport(Darwin)
            let sections = try sectionsMatching([("__LLVM", "__remarks")])

            // We expect a single section, otherwise we bail
            guard !sections.isEmpty else { return nil }
            guard sections.count == 1 else { throw BinaryReaderError.parseError("Found multiple __remarks sections") }
            let (swap, section) = sections[0]

            reader.push()
            defer { reader.pop() }

            let sectionReader = try reader.seek(by: Int(section.section.offset.byteSwappedIfNeeded(swap)))
            return Data(try sectionReader.read(count: Int(section.section.size64)))
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }
    }
}

@available(*, unavailable)
extension MachO: Sendable { }

@available(*, unavailable)
extension MachO.Slice: Sendable { }

#if canImport(Darwin)
@available(*, unavailable)
extension MachO.Slice.LoadCommand: Sendable { }

@available(*, unavailable)
extension MachO.Slice.Segment: Sendable { }
#endif

fileprivate extension Version {
    init(machOVersion v: UInt32) {
        self = Version(UInt(v) >> 16, (UInt(v) >> 8) & 0xFF, UInt(v) & 0xFF)
    }
}

// A representation of a static archive, but thin and fat archives are supported. This is an internal implementation detail to help with parsing static archives. Everything should still go through `MachO`.
@_spi(Testing) public struct StaticArchive {
    static let symbolTables = [SYMDEF, SYMDEF_SORTED, SYMDEF_64, SYMDEF_64_SORTED]

    /// The first word in the ARMAG constant.
    static let ARMAG1: UInt32 = 0x213c6172

    /// The second word in the ARMAG constant.
    static let ARMAG2: UInt32 = 0x63683e0a
    /// The type of static archive.
    public enum ArchiveType: Sendable {
        /// Only a single architecture is included.
        case thin

        /// Multiple architectures are contained within the static archive.
        case fat(magic: UInt32)

        /// Returns true if the given archive is `fat`.
        @_spi(Testing) public var isFatArchive: Bool {
            switch self {
            case .fat(_): return true
            default: return false
            }
        }

        /// Tries to initialize the static archive type based on the given binary representation.
        init(reader: any BinaryReaderView) throws {
            let magic: UInt32 = try reader.peek()

            switch magic {
            case UInt32(bigEndian: ARMAG1):
                let magic2: UInt32 = try reader.peek(offset: MemoryLayout<UInt32>.size)
                if magic2 == UInt32(bigEndian: ARMAG2) {
                    self = .thin
                }
                else {
                    throw BinaryReaderError.parseError("Unknown header: 0x\(String(magic, radix: 16)) 0x\(String(magic2, radix: 16))")
                }

            case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
                self = .fat(magic: magic)

            default:
                throw BinaryReaderError.parseError("Unknown header: 0x\(String(magic, radix: 16))")
            }
        }
    }

    /// The type of archive.
    public let archiveType: ArchiveType

    /// The reader for the raw binary representation of the static archive.
    private let reader: BinaryReader

    public init(reader: BinaryReader) throws {
        self.reader = reader
        self.archiveType = try ArchiveType(reader: reader)
    }

    /// Retrieves all of the individual Mach-O files within an archive.
    public func machOs() throws -> [MachO] {
        switch archiveType {
        case .thin:
            #if canImport(Darwin.ar)
            // The magic bytes '!<arch>\n' has already been established, so skip past that.
            try self.reader.seek(by: Int(SARMAG))

            var machOs: [MachO] = []

            // Attempt to read all of the archive headers out of the content.
            while !reader.eof {
                let archiveHeader: ar_hdr = try reader.read()

                // Capture the current reader state so we can properly increment past each archive.
                reader.push()

                let archiveName = try { () throws -> String? in
                    if let nameSize = archiveHeader.extendedFormatArchiveNameSize {
                        return [UInt8](try reader.read(count: nameSize)).withUnsafeBytes({ rawPtr in
                            if let cString = rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self) {
                                // The length of the filename from the header always seems to include 4 NULL padding bytes...
                                return FileManager.default.string(withFileSystemRepresentation: cString, length: rawPtr.count).trimmingCharacters(in: CharacterSet(["\0"]))
                            }
                            return nil
                        })
                    }
                    return archiveHeader.rawArchiveName
                }() ?? ""

                guard let objectSize = archiveHeader.objectSize, objectSize > 0 else {
                    throw BinaryReaderError.parseError("Encountered zero-length static archive")
                }

                // Make sure to skip the archive member which is the symbol table
                if !StaticArchive.symbolTables.contains(archiveName) {
                    machOs.append(try MachO(reader: BinaryReader(data: reader.data, startingAt: reader.offset, size: objectSize)))
                }

                // Return back to the reader's state to when the header was read.
                reader.pop()

                try reader.seek(by: objectSize.nextEvenNumber() + (archiveHeader.extendedFormatArchiveNameSize ?? 0))
            }

            return machOs
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        case let .fat(magic):
            let archs: [any MachOFatHeader] = try .init(reader: reader)
            let swap = shouldSwap(magic: magic)

            do {
                return try archs.flatMap { arch throws -> [MachO] in
                    return try StaticArchive(reader: BinaryReader(data: reader.data, startingAt: Int(arch.offset(byteSwappedIfNeeded: swap)), size: Int(arch.size(byteSwappedIfNeeded: swap)))).machOs()
                }
            }
        }
    }
}

@available(*, unavailable)
extension StaticArchive: Sendable { }

#if canImport(Darwin.ar)
extension ar_hdr {
    public var rawArchiveName: String? {
        var tmp = ar_name
        return withUnsafeBytes(of: &tmp) { rawPtr in
            if let cString = rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self) {
                return FileManager.default.string(withFileSystemRepresentation: cString, length: rawPtr.count)
            }
            return nil
        }
    }

    public var extendedFormatArchiveNameSize: Int? {
        if let rawArchiveName, rawArchiveName.hasPrefix(AR_EFMT1) {
            return Int(rawArchiveName.withoutPrefix(AR_EFMT1).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public var objectSize: Int? {
        var tmp = ar_size
        return withUnsafeBytes(of: &tmp) { rawPtr in
            if let s = String(bytes: rawPtr, encoding: .utf8), let size = Int(s.trimmingCharacters(in: .whitespaces)) {
                return size - (extendedFormatArchiveNameSize ?? 0)
            }
            return nil
        }
    }

    /// The number of bytes the `ar_hdr` occupies.
    public var structSize: Int {
        return MemoryLayout<ar_hdr>.size
    }
}
#endif

extension Array where Element == any MachOFatHeader {
    init(reader: BinaryReader) throws {
        #if canImport(Darwin)
        let fh: fat_header = try reader.read()
        let swap = shouldSwap(magic: fh.magic)
        let nfat_arch = fh.nfat_arch.byteSwappedIfNeeded(swap)

        let is64bit = fh.magic == FAT_MAGIC_64 || fh.magic == FAT_CIGAM_64

        var archs: [any MachOFatHeader] = try (0 ..< nfat_arch).map { _ in
            if is64bit {
                return try reader.read() as fat_arch_64
            } else {
                return try reader.read() as fat_arch
            }
        }

        // Special case hidden CPU_TYPE_ARM64. nfat_arch says N, but arm64 is at N+1, to hide it from OS versions which cannot process it correctly. Note that lipo itself is capable of _writing_ multiple hidden arm64 slices, but it will only _read_ a single hidden arm64 slice. We'll only read one, since that seems to have been the intent (and predates arm64e).

        if let firstSliceOffset = archs.map({ $0.offset(byteSwappedIfNeeded: swap) }).min(), reader.offset < firstSliceOffset - UInt64(is64bit ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size) {
            let hiddenSliceReader = BinaryReader(data: reader.data, startingAt: reader.offset, size: Int(firstSliceOffset) - reader.offset)
            if !hiddenSliceReader.eof {
                let arch: any MachOFatHeader
                if is64bit {
                    arch = try hiddenSliceReader.read() as fat_arch_64
                } else {
                    arch = try hiddenSliceReader.read() as fat_arch
                }

                if arch.cputype.byteSwappedIfNeeded(true) == CPU_TYPE_ARM64 {
                    archs.append(arch)
                }
            }
        }

        self = archs
        #else
        throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
        #endif
    }
}

extension MachO.Slice {

    /// Returns `true` if this slice contains a `__swift5_entry` text section.
    public var containsSwift5EntrySection: Bool {
        get throws {
            #if canImport(Darwin)
            for segment in try segments() {
                for section in try segment.sections() {
                    let segname = try section.section.segname()
                    let sectname = try section.section.sectname()

                    guard segname == "__TEXT" else { continue }
                    if sectname == "__swift5_entry" {
                        return true
                    }
                }
            }
            return false
            #else
            throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
            #endif
        }
    }

}
