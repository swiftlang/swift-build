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

public import SWBUtil

public import struct Foundation.Data
public import class Foundation.PropertyListDecoder
public import class Foundation.PropertyListEncoder
public import protocol Foundation.LocalizedError
public import SWBMacro
import Synchronization

/// Represents the various types of error cases possible when constructing an `XCFramework` type.
///
/// - remark: When adding to this enum, add a test for it to `XCFrameworkTests.testXCFrameworkValidationErrors()`.
public enum XCFrameworkValidationError: Error, Equatable {
    /// The version specified is not a supported format version.
    case unsupportedVersion(version: String)

    /// The `libraries` set is empty, which is an invalid state.
    case noLibraries

    /// An unsupported library type was used. The library type and the identifier of the library within the XCFramework is also identified.
    case unsupportedLibraryType(libraryType: XCFramework.LibraryType, libraryIdentifier: String)

    /// An XCFramework only supports homogeneous library types.
    case mixedLibraryTypes(libraryType: XCFramework.LibraryType, otherLibraryType: XCFramework.LibraryType)

    /// The library path is empty.
    case libraryPathEmpty(libraryIdentifier: String)

    /// The supported platform is empty.
    case supportedPlatformEmpty(libraryIdentifier: String)

    /// The headers path is empty.
    case headersPathEmpty(libraryIdentifier: String)

    /// The debug symbols path is empty.
    case debugSymbolsPathEmpty(libraryIdentifier: String)

    /// The platform variant is empty.
    case platformVariantEmpty(libraryIdentifier: String)

    /// The library type does not support specifying a headers location.
    case headerPathNotSupported(libraryType: XCFramework.LibraryType, libraryIdentifier: String)

    /// When multiple libraries can be matched based on platform and platform variant. This would result in `findLibrary()` having multiple matches.
    case conflictingLibraryDefinitions(libraryIdentifier: String, otherLibraryIdentifier: String)

    /// When multiple libraries contain the same library identifier. This is used as the path within the XCFramework, so it must be unique.
    case duplicateLibraryIdentifier(libraryIdentifier: String)

    /// The Info.plist file is missing from the XCFramework.
    case missingInfoPlist(path: Path)

    /// Error message when the `Info.plist` defines a key describing a path location that should exist on disk but is missing.
    case missingPathEntry(xcframeworkPath: Path, libraryIdentifier: String, plistKey: String, plistValue: String)

    /// The actual XCFramework is missing on disk.
    case missingXCFramework(path: Path)

    /// The library is marked as having mergeable metadata but is of a type which doesn't support that.
    /// - remark: Xcode support for mergeable libraries involves special code for embedding the product, so explicit support for new types will need to be added.  Users can't just create some random bundle and expect Xcode to handle it properly.
    case libraryTypeDoesNotSupportMergeableMetadata(libraryType: XCFramework.LibraryType)

    /// The library is marked as having mergeable metadata but does not have a binary path, which is needed to process such libraries.
    case mergeableLibraryBinaryPathEmpty(libraryIdentifier: String)
}

extension XCFrameworkValidationError: LocalizedError {

    /// The user-facing error message to output for any given `XCFrameworkValidationError`.
    public var errorDescription: String? {
        func libraryErrorMessage(_ text: String, libraryIdentifier: String) -> String {
            return "\(text) in library '\(libraryIdentifier)'."
        }

        switch self {
        case let .unsupportedVersion(version):
            return "Version \(version) is not supported (maximum version \(XCFramework.currentVersion))."

        case .noLibraries:
            return "There are no libraries provided for the XCFramework."

        case let .unsupportedLibraryType(libraryType, libraryIdentifier):
            return libraryErrorMessage("Unknown library type with extension '\(libraryType.fileExtension)'", libraryIdentifier: libraryIdentifier)

        case let .mixedLibraryTypes(libraryType, otherLibraryType):
            return "An XCFramework cannot be composed of different library types: '\(libraryType.libraryTypeName)' and '\(otherLibraryType.libraryTypeName)'."

        case let .libraryPathEmpty(libraryIdentifier):
            return libraryErrorMessage("The '\(XCFrameworkInfoPlist_V1.Library.CodingKeys.libraryPath.stringValue)' is empty", libraryIdentifier: libraryIdentifier)

        case let .supportedPlatformEmpty(libraryIdentifier):
            return libraryErrorMessage("The '\(XCFrameworkInfoPlist_V1.Library.CodingKeys.supportedPlatform.stringValue)' is empty", libraryIdentifier: libraryIdentifier)

        case let .headersPathEmpty(libraryIdentifier):
            return libraryErrorMessage("The '\(XCFrameworkInfoPlist_V1.Library.CodingKeys.headersPath.stringValue)' is empty", libraryIdentifier: libraryIdentifier)

        case let .debugSymbolsPathEmpty(libraryIdentifier):
            return libraryErrorMessage("The '\(XCFrameworkInfoPlist_V1.Library.CodingKeys.debugSymbolsPath.stringValue)' is empty", libraryIdentifier: libraryIdentifier)

        case let .platformVariantEmpty(libraryIdentifier):
            return libraryErrorMessage("The '\(XCFrameworkInfoPlist_V1.Library.CodingKeys.platformVariant.stringValue)' is empty", libraryIdentifier: libraryIdentifier)

        case let .headerPathNotSupported(libraryType, libraryIdentifier):
            return libraryErrorMessage("'\(XCFrameworkInfoPlist_V1.Library.CodingKeys.headersPath.stringValue)' is not supported for a '\(libraryType.libraryTypeName)'", libraryIdentifier: libraryIdentifier)

        case let .conflictingLibraryDefinitions(libraryIdentifier, otherLibraryIdentifier):
            return "Both '\(libraryIdentifier)' and '\(otherLibraryIdentifier)' represent two equivalent library definitions."

        case let .duplicateLibraryIdentifier(libraryIdentifier):
            return "A library with the identifier '\(libraryIdentifier)' already exists."

        case let .missingInfoPlist(path):
            return "There is no Info.plist found at '\(path.str)'."

        case let .missingPathEntry(xcframeworkPath, libraryIdentifier, plistKey, plistValue):
            let path = xcframeworkPath.join(libraryIdentifier).join(plistValue)
            return "Missing path (\(path.str)) from XCFramework '\(xcframeworkPath.basename)' as defined by '\(plistKey)' in its `Info.plist` file"

        case let .missingXCFramework(path):
            return "There is no XCFramework found at '\(path.str)'."

        case let .libraryTypeDoesNotSupportMergeableMetadata(libraryType):
            switch libraryType {
            case .staticLibrary:
                return "Static libraries do not support mergeable metadata, only frameworks and dynamic libraries are supported."
            case .unknown(let fileExtension):
                return "Files with extension '\(fileExtension) do not support mergeable metadata, only frameworks and dynamic libraries are supported."
            case .framework, .dynamicLibrary:
                // We should not have been created with one of these types.
                return "Internal error: libraryTypeDoesNotSupportMergeableMetadata created for type \(libraryType.libraryTypeName) even though that type supports mergeable metadata."
            }

        case let .mergeableLibraryBinaryPathEmpty(libraryIdentifier):
            return libraryErrorMessage("'\(XCFrameworkInfoPlist_V1.Library.CodingKeys.mergeableMetadata.stringValue)' is true but the '\(XCFrameworkInfoPlist_V1.Library.CodingKeys.binaryPath.stringValue)' is empty", libraryIdentifier: libraryIdentifier)
        }
    }
}

/// Represents and error that happens during the creation of an xcframework.
public struct XCFrameworkCreationError: Error {
    /// The message for the error.
    @_spi(Testing) public let message: String
}

extension XCFrameworkCreationError: LocalizedError {
    /// Provide a better error message when using `localizedDescription` on error types.
    public var errorDescription: String? {
        return message
    }
}

/// Defines the structure format for an XCFramework wrapper.
public struct XCFramework: Hashable, Sendable {
    /// The list of supported library types and their extensions.
    public enum LibraryType: Equatable, CustomStringConvertible, Sendable {
        /// A framework type. Currently no distinction is made between static or dynamic.
        case framework

        /// A dynamic library.
        case dynamicLibrary

        /// A static library.
        case staticLibrary

        /// An unknown library type.
        case unknown(fileExtension: String)

        /// Determines if the given library type supports being packaged with headers.
        public var canHaveHeaders: Bool {
            switch self {
            case .dynamicLibrary: return true
            case .staticLibrary: return true
            default: return false
            }
        }

        /// A user-facing description of the type of library contained within.
        public var description: String {
            switch self {
            case .framework: return "framework"
            default: return "library"
            }
        }

        /// A user-facing name for each of the given library types.
        public var libraryTypeName: String {
            switch self {
            case .framework: return "framework"
            case .dynamicLibrary: return "dynamic library"
            case .staticLibrary: return "static library"
            case .unknown(let fileExtension): return "unknown (\(fileExtension))"
            }
        }

        /// Returns the file extension for the given `XCFramework.LibraryType`.
        public var fileExtension: String {
            switch self {
            case .framework: return "framework"
            case .dynamicLibrary: return "dylib"
            case .staticLibrary: return "a"
            case .unknown(let fileExtension): return fileExtension
            }
        }

        /// Creates a new `LibraryType` from the given file extension.
        public init(fileExtension: String) {
            let ext = fileExtension.lowercased()

            switch ext {
            case "framework": self = .framework; break
            case "dylib": self = .dynamicLibrary; break
            case "a": self = .staticLibrary; break
            default: self = .unknown(fileExtension: ext)
            }
        }
    }

    /// Information on the libraries the xcframework bundles.
    public struct Library: Sendable {
        /// A unique identifier for the library. This will typically be in the target-triple form: `x86_64-apple-macos`. However, it can be any unique string amongst the other available libraries.
        ///
        /// This identifier is also used as the name of the directory the library and any other related contents can be found.
        ///
        /// This string needs to be a valid path identifier.
        public let libraryIdentifier: String

        /// The platform the library corresponds to.
        ///
        /// These are the same values as the OS field of an LLVM target triple. Examples of recognized values therefore include but are not limited to:
        /// - driverkit
        /// - ios
        /// - macos
        /// - tvos
        /// - watchos
        ///
        /// Note that a Mac Catalyst library will have a `platform` of 'ios' - not 'macos' - but a `platformVariant` of 'macabi'.
        public let supportedPlatform: String

        /// The listing of supported architectures.
        ///
        /// These are the same values as the arch + subarch field of an LLVM target triple. Examples of recognized values therefore include but are not limited to:
        /// - arm64
        /// - arm64_32
        /// - arm64e
        /// - armv7
        /// - armv7k
        /// - armv7s
        /// - i386
        /// - x86_64
        /// - x86_64h
        public let supportedArchitectures: OrderedSet<String>

        /// Used to specify a specific variant that should be used, such as macCatalyst or the simulator.
        ///
        /// These are the same values as the environment field of an LLVM target triple. Examples of recognized values therefore include but are not limited to:
        /// - macabi
        /// - simulator
        public let platformVariant: String?

        /// The relative path to the top-level library or framework. Typically just the name of the library or framework.
        public let libraryPath: Path

        /// The relative path to the binary. For a library this will just be the name of the library. For a framework this will be the path starting with the name of the framework. This is mainly needed to deal with the macOS framework bundle layout.
        /// - remark: This property is optional because it is new in Xcode 15, but is always archived to version 1.0 plists because older versions of Xcode can ignore it.
        public let binaryPath: Path?

        /// The relative path to the headers. Typically 'Headers'.
        public let headersPath: Path?

        /// The relative path to the debug symbols. Typically 'dSYMs'.
        public let debugSymbolsPath: Path?

        /// If true, then the library contains mergeable metadata (an `LC_ATOM_INFO` section) in all of its architecture slices).
        /// - remark: XCFrameworks which declare this property can only be used by Xcodes which support v1.1 or later.
        public let mergeableMetadata: Bool

        /// The library type for the given `Library`.
        public let libraryType: LibraryType

        public init(libraryIdentifier: String, supportedPlatform: String, supportedArchitectures: OrderedSet<String>, platformVariant: String?, libraryPath: Path, binaryPath: Path?, headersPath: Path?, debugSymbolsPath: Path? = nil, mergeableMetadata: Bool = false) {
            self.libraryIdentifier = libraryIdentifier
            self.supportedPlatform = supportedPlatform
            self.supportedArchitectures = supportedArchitectures
            self.platformVariant = platformVariant?.nilIfEmpty // remove the property if it is empty
            self.libraryPath = libraryPath
            self.binaryPath = binaryPath
            self.headersPath = headersPath
            self.debugSymbolsPath = debugSymbolsPath
            self.mergeableMetadata = mergeableMetadata

            self.libraryType = XCFramework.LibraryType(fileExtension: libraryPath.fileExtension)
        }
    }

    /// The version of the bundle format. Follows semver.
    public let version: Version

    /// A set of each of the available bundles.
    public let libraries: OrderedSet<Library>

    /// Creates a new instance validating that new XCFramework will be valid. Any validation errors will be surfaced with an `XCFrameworkValidationError`.
    public init(version: Version, libraries: OrderedSet<Library>) throws {
        self.version = version
        self.libraries = libraries

        try self.validate()
    }

    /// Creates a new instance validating that new XCFramework will be valid. Any validation errors will be surfaced with an `XCFrameworkValidationError`.
    public init(version: Version, libraries: [Library]) throws {
        self.version = version

        var libs = OrderedSet<Library>()
        for lib in libraries {
            if libs.append(lib).inserted == false {
                throw XCFrameworkValidationError.duplicateLibraryIdentifier(libraryIdentifier: lib.libraryIdentifier)
            }
        }
        self.libraries = libs

        try self.validate()
    }

    /// Creates a new instance validating that new XCFramework will be valid. Any validation errors will be surfaced with an `XCFrameworkValidationError`. The version will be computed from the libraries passed in.
    public init(libraries: [Library]) throws {
        let version = Self.xcframeworkVersion(for: libraries)
        try self.init(version: version, libraries: libraries)
    }

    /// Computes the version of the XCFramework being created based on the contents of the `Library`s passed in.
    fileprivate static func xcframeworkVersion(for libraries: [Library]) -> Version {
        var version = Version(1, 0)

        // We work through all of the properties which are not supported by older versions, and end up with a version which supports the newest property which is present.
        func setVersionIfNewer(_ candidate: Version) {
            if version < candidate {
                version = candidate
            }
        }

        // We only bump to the mergeableMetadataVersion if at least one library has mergeableMetadata set to true.
        if libraries.contains(where: { $0.mergeableMetadata }) {
            setVersionIfNewer(mergeableMetadataVersion)
        }

        return version
    }

    /// The highest XCFramework version which this Swift Build supports.
    static let currentVersion = Version(1, 1)
    /// The minimum XCFramework version required to support mergeable metadata.
    @_spi(Testing) public static let mergeableMetadataVersion = Version(1, 1)

    /// Searches the `libraries` based on the current SDK being used.
    public func findLibrary(sdk: SDK?, sdkVariant: SDKVariant?) -> XCFramework.Library? {
        // Lookup the LC_BUILD_VERSION information as that it is how xcframeworks platform and variant values are defined.
        guard let platformName = sdkVariant?.llvmTargetTripleSys else {
            return nil
        }
        return findLibrary(platform: platformName, platformVariant: sdkVariant?.llvmTargetTripleEnvironment ?? "")
    }

    /// Given a platform and the variant, attempt to find an library within the XCFramework that can be used.
    public func findLibrary(platform: String, platformVariant: String = "") -> XCFramework.Library? {
        return self.libraries.filter { lib in
            // Due to the fact that macro evaluation of empty settings returns empty strings, there is no meaningful distinction between nil and empty here.
            lib.supportedPlatform == platform && (lib.platformVariant ?? "") == platformVariant
        }.first
    }
}

extension XCFramework {
    private struct LibraryKey: Hashable {
        let identifier: String
        let platform: String
        let platformVariant: String?

        func hash(into hasher: inout Hasher) {
            // identifier is only used for tracking the offending library
            hasher.combine(platform)
            hasher.combine(platformVariant)
        }

        static func == (lhs: LibraryKey, rhs: LibraryKey) -> Bool {
            return lhs.platform == rhs.platform && lhs.platformVariant == rhs.platformVariant
        }
    }

    /// Performs the necessary set of validations on the elements within the XCFramework. This is used during construction time.
    fileprivate func validate() throws {
        guard self.version <= Self.currentVersion else {
            throw XCFrameworkValidationError.unsupportedVersion(version: self.version.description)
        }

        guard let library = self.libraries.first else {
            throw XCFrameworkValidationError.noLibraries
        }

        let firstLibraryType = library.libraryType
        var libraryKeys = Set<LibraryKey>()

        for library in self.libraries {
            // Implementation Note: This validation *must* come before the library type check, otherwise, this error will never be surfaced due to the fact that the library type will be `unknown` for an empty library path.
            guard !library.libraryPath.isEmpty else {
                throw XCFrameworkValidationError.libraryPathEmpty(libraryIdentifier: library.libraryIdentifier)
            }

            if case .unknown(_) = library.libraryType {
                throw XCFrameworkValidationError.unsupportedLibraryType(libraryType: library.libraryType, libraryIdentifier: library.libraryIdentifier)
            }

            guard firstLibraryType == library.libraryType else {
                throw XCFrameworkValidationError.mixedLibraryTypes(libraryType: firstLibraryType, otherLibraryType: library.libraryType)
            }

            guard !library.supportedPlatform.isEmpty else {
                throw XCFrameworkValidationError.supportedPlatformEmpty(libraryIdentifier: library.libraryIdentifier)
            }

            if let headersPath = library.headersPath {
                guard !headersPath.isEmpty else {
                    throw XCFrameworkValidationError.headersPathEmpty(libraryIdentifier: library.libraryIdentifier)
                }
            }

            if let debugSymbolsPath = library.debugSymbolsPath {
                guard !debugSymbolsPath.isEmpty else {
                    throw XCFrameworkValidationError.debugSymbolsPathEmpty(libraryIdentifier: library.libraryIdentifier)
                }
            }

            if let platformVariant = library.platformVariant {
                guard !platformVariant.isEmpty else {
                    throw XCFrameworkValidationError.platformVariantEmpty(libraryIdentifier: library.libraryIdentifier)
                }
            }

            if library.mergeableMetadata {
                // Only frameworks and dylibs support mergeable metadata.
                switch library.libraryType {
                case .framework, .dynamicLibrary:
                    // These are fine.
                    break
                default:
                    throw XCFrameworkValidationError.libraryTypeDoesNotSupportMergeableMetadata(libraryType: library.libraryType)
                }

                // There must be a binaryPath if mergeableMetadata is true.
                if library.binaryPath == nil || library.binaryPath!.isEmpty {
                    throw XCFrameworkValidationError.mergeableLibraryBinaryPathEmpty(libraryIdentifier: library.libraryIdentifier)
                }
            }

            if case .framework = library.libraryType, library.headersPath != nil {
                throw XCFrameworkValidationError.headerPathNotSupported(libraryType: library.libraryType, libraryIdentifier: library.libraryIdentifier)
            }

            let (added, oldMember) = libraryKeys.insert(LibraryKey(identifier: library.libraryIdentifier, platform: library.supportedPlatform, platformVariant: library.platformVariant))
            guard added == true else {
                throw XCFrameworkValidationError.conflictingLibraryDefinitions(libraryIdentifier: oldMember.identifier, otherLibraryIdentifier: library.libraryIdentifier)
            }
        }
    }
}

extension XCFramework.Library: Hashable {
    /// The `libraryIdentifier` is used to determine if two XCFrameworks are unique.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.libraryIdentifier)
    }

    /// Returns `true` iff the `libraryIdentifiers` are equal. The rest of the library components are not used for equality.
    static public func ==(lhs: XCFramework.Library, rhs: XCFramework.Library) -> Bool {
        return lhs.libraryIdentifier == rhs.libraryIdentifier
    }
}

// MARK: XCFramework (v1) Info.plist parsing.

/// This is an internal representation of the plist structure for v1 of the XCFramework. This is used in order to completely decouple the parsing structure from the actual data model structure. Doing this gains us better ability to version the XCFrameworks, and provides us a better mechanism to catch parsing errors vs. validation errors; if we only used the data model, certain validation errors would be lost in the `Codable` translation.
///
/// - remark: See the `XCFramework` struct and its nested structs for documentation about the individual fields. This struct only documents details about archiving the contents, not the meaning of the contents.
///
/// - remark: As time of writing this is the only version, and we can iterate on it as needed.  If we ever radically transform the format (rather than just adding and removing keys) then we may create a new struct for the reworked version.
@_spi(Testing) public struct XCFrameworkInfoPlist_V1: Codable {
    struct Library: Codable {
        let libraryIdentifier: String
        let supportedPlatform: String
        let supportedArchitectures: [String]
        let platformVariant: String?
        let libraryPath: String
        // This is optional because XCFrameworks created with Xcode 14.x and earlier will not define it, but should still be usable.
        let binaryPath: String?
        let headersPath: String?
        let debugSymbolsPath: String?
        // This is optional because we only want to encode it if the XCFramework is at least of the version which supports it, but this struct doesn't know what that is, so we capture that characteristic in XCFramework.serialize() where the version is available.
        let mergeableMetadata: Bool?

        enum CodingKeys: String, CodingKey {
            case libraryIdentifier = "LibraryIdentifier"
            case supportedPlatform = "SupportedPlatform"
            case supportedArchitectures = "SupportedArchitectures"
            case platformVariant = "SupportedPlatformVariant"
            case libraryPath = "LibraryPath"
            case binaryPath = "BinaryPath"
            case headersPath = "HeadersPath"
            case debugSymbolsPath = "DebugSymbolsPath"
            case mergeableMetadata = "MergeableMetadata"
            // Bitcode is no longer supported, but we still recognize the key for older XCFrameworks which define it.
            case bitcodeSymbolMapsPath = "BitcodeSymbolMapsPath"
        }

        init(libraryIdentifier: String, supportedPlatform: String, supportedArchitectures: [String], platformVariant: String?, libraryPath: String, binaryPath: String?, headersPath: String?, debugSymbolsPath: String?, mergeableMetadata: Bool?) {
            self.libraryIdentifier = libraryIdentifier
            self.supportedPlatform = supportedPlatform
            self.supportedArchitectures = supportedArchitectures
            self.platformVariant = platformVariant
            self.libraryPath = libraryPath
            self.binaryPath = binaryPath
            self.headersPath = headersPath
            self.debugSymbolsPath = debugSymbolsPath
            self.mergeableMetadata = mergeableMetadata
        }

        // NOTE: The mappings for maccatalyst are so that "macabi" is used as that is what is directly matched in the LC_BUILD_VERSION info.

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(libraryIdentifier, forKey: .libraryIdentifier)
            try container.encode(supportedPlatform, forKey: .supportedPlatform)
            try container.encode(supportedArchitectures, forKey: .supportedArchitectures)

            if platformVariant == "macabi" {
                try container.encode("maccatalyst", forKey: .platformVariant)
            }
            else {
                try container.encodeIfPresent(platformVariant, forKey: .platformVariant)
            }

            try container.encode(libraryPath, forKey: .libraryPath)
            try container.encode(binaryPath, forKey: .binaryPath)
            try container.encodeIfPresent(headersPath, forKey: .headersPath)
            try container.encodeIfPresent(debugSymbolsPath, forKey: .debugSymbolsPath)
            try container.encodeIfPresent(mergeableMetadata, forKey: .mergeableMetadata)
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.libraryIdentifier = try container.decode(String.self, forKey: .libraryIdentifier)
            self.supportedPlatform = try container.decode(String.self, forKey: .supportedPlatform)
            self.supportedArchitectures = try container.decode([String].self, forKey: .supportedArchitectures)
            var platformVariant = try container.decodeIfPresent(String.self, forKey: .platformVariant)
            if platformVariant == "maccatalyst" {
                platformVariant = "macabi"
            }
            self.platformVariant = platformVariant

            self.libraryPath = try container.decode(String.self, forKey: .libraryPath)
            self.binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath)
            self.headersPath = try container.decodeIfPresent(String.self, forKey: .headersPath)
            self.debugSymbolsPath = try container.decodeIfPresent(String.self, forKey: .debugSymbolsPath)
            self.mergeableMetadata = try container.decodeIfPresent(Bool.self, forKey: .mergeableMetadata)
            // Bitcode is no longer supported, but we still recognize the key for older XCFrameworks which define it.
            let _ = try container.decodeIfPresent(String.self, forKey: .bitcodeSymbolMapsPath)
        }
    }

    let version: String
    let libraries: [Library]

    let bundleCode: String = "XFWK"

    enum CodingKeys: String, CodingKey {
        case version = "XCFrameworkFormatVersion"
        case libraries = "AvailableLibraries"
        case bundleCode = "CFBundlePackageType"
    }
}

extension XCFramework {
    public init(path: Path, fs: any FSProxy) throws {
        let decoder = PropertyListDecoder()

        guard fs.exists(path) else {
            throw XCFrameworkValidationError.missingXCFramework(path: path)
        }

        let plistPath = path.join("Info.plist")
        guard fs.exists(plistPath) else {
            throw XCFrameworkValidationError.missingInfoPlist(path: plistPath)
        }

        let data = Data(try fs.read(plistPath).bytes)
        let xcframeworkv1: XCFrameworkInfoPlist_V1
        do {
            xcframeworkv1 = try decoder.decode(XCFrameworkInfoPlist_V1.self, from: data)
        } catch {
            throw StubError.error("Failed to decode XCFramework Info.plist at '\(plistPath.str)': \(error.localizedDescription)")
        }

        do {
            try self.init(other: xcframeworkv1)
        } catch {
            throw StubError.error("Failed to load XCFramework at '\(path.str)': \(error.localizedDescription)")
        }
    }

    @_spi(Testing) public init(other: XCFrameworkInfoPlist_V1) throws {
        let version: Version
        let libraries: [XCFramework.Library]
        do {
            version = try Version(other.version)
        }
        catch {
            throw XCFrameworkValidationError.unsupportedVersion(version: other.version)
        }

        libraries = other.libraries.map { XCFramework.Library(other: $0) }
        try self.init(version: version, libraries: libraries)
    }

    public func serialize() throws -> Data {
        let libraries = self.libraries.map { lib in
            // We only archive the mergeableMetadata property if we're the version which supports it or higher, so we set it to nil if we're a lower version.
            let mergeableMetadata: Bool? = (version >= type(of: self).mergeableMetadataVersion) ? lib.mergeableMetadata : nil
            return XCFrameworkInfoPlist_V1.Library(libraryIdentifier: lib.libraryIdentifier, supportedPlatform: lib.supportedPlatform, supportedArchitectures: lib.supportedArchitectures.elements, platformVariant: lib.platformVariant, libraryPath: lib.libraryPath.str, binaryPath: lib.binaryPath?.str, headersPath: lib.headersPath?.str, debugSymbolsPath: lib.debugSymbolsPath?.str, mergeableMetadata: mergeableMetadata)
        }
        let xcframeworkV1 = XCFrameworkInfoPlist_V1(version: version.description, libraries: libraries)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(xcframeworkV1)
    }
}

extension XCFramework.Library {
    init(other: XCFrameworkInfoPlist_V1.Library) {
        let libraryIdentifier = other.libraryIdentifier
        let supportedPlatform = other.supportedPlatform

        // silently ignoring supported architectures is fine as there is not real impact on the data model processing
        let supportedArchitectures = OrderedSet(other.supportedArchitectures)
        let platformVariant = other.platformVariant
        let libraryPath = Path(other.libraryPath)
        let binaryPath = other.binaryPath.flatMap { Path($0) }
        let headersPath = other.headersPath.flatMap { Path($0) }
        let debugSymbolsPath = other.debugSymbolsPath.flatMap { Path($0) }
        let mergeableMetadata = other.mergeableMetadata ?? false

        self.init(libraryIdentifier: libraryIdentifier, supportedPlatform: supportedPlatform, supportedArchitectures: supportedArchitectures, platformVariant: platformVariant, libraryPath: libraryPath, binaryPath: binaryPath, headersPath: headersPath, debugSymbolsPath: debugSymbolsPath, mergeableMetadata: mergeableMetadata)
    }
}

// MARK: XCFramework Extensions

extension XCFramework {
    /// Determines the location that the processed xcframework output should go to.
    public static func computeOutputDirectory(_ scope: MacroEvaluationScope) -> Path {

        let subfolder: Path
        if scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
            subfolder = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        }
        else {
            subfolder = scope.unmodifiedTargetBuildDir
        }

        // Trim any trailing slashes, as the result is directly combined in spec files.
        return subfolder.withoutTrailingSlash()
    }
}

//  MARK: XCFramework CLI creation

extension XCFramework {
    /// Represents one of the possible command line arguments passed.
    @_spi(Testing) public enum Argument: Equatable {
        case framework(path: Path, debugSymbolPaths: [Path] = [])
        case library(path: Path, headersPath: Path?, debugSymbolPaths: [Path] = [])
        case output(path: Path)
        case internalDistribution

        var libraryPath: Path? {
            if case let .library(path, _, _) = self { return path }
            else { return nil }
        }

        var headersPath: Path? {
            if case let .library(_, path, _) = self { return path }
            else { return nil }
        }

        var debugSymbolPaths: [Path] {
            if case let .library(_, _, path) = self { return path }
            if case let .framework(_, path) = self { return path }
            return []
        }

        var outputPath: Path? {
            if case let .output(path) = self { return path }
            return nil
        }
    }

    public static func usage() -> String {
        return
            """
            OVERVIEW: Utility for packaging multiple build configurations of a given library or framework into a single xcframework.

            USAGE:
            xcodebuild -create-xcframework -framework <path> [-framework <path>...] -output <path>
            xcodebuild -create-xcframework -library <path> [-headers <path>] [-library <path> [-headers <path>]...] -output <path>

            OPTIONS:
            -archive <path>                 Adds a framework or library from the archive at the given <path>. Use with -framework or -library.
            -framework <path|name>          Adds a framework from the given <path>.
                                            When used with -archive, this should be the name of the framework instead of the full path.
            -library <path|name>            Adds a static or dynamic library from the given <path>.
                                            When used with -archive, this should be the name of the library instead of the full path.
            -headers <path>                 Adds the headers from the given <path>. Only applicable with -library.
            -debug-symbols <path>           Adds the debug symbols (dSYMs or bcsymbolmaps) from the given <path>. Can be applied multiple times. Must be used with -framework or -library.
            -output <path>                  The <path> to write the xcframework to.
            -allow-internal-distribution    Specifies that the created xcframework contains information not suitable for public distribution.
            -help                           Show this help content.
            """
    }

    @_spi(Testing) public enum CommandLineParsingResult {
        case arguments([Argument], allowInternalDistribution: Bool)
        case help
    }

    @_spi(Testing) public static func rewriteCommandLine(_ commandLine: [String], cwd currentWorkingDirectory: Path, fs: any FSProxy) -> [String] {
        precondition(currentWorkingDirectory.isAbsolute)

        func rewriteDebugSymbolCommandLine(_ archiveRoot: Path, _ name: String, _ fs: any FSProxy, _ newCommandLine: inout [String]) {
            let dsym = archiveRoot.join("dSYMs").join("\(name).dSYM")
            if fs.isDirectory(dsym) || fs.exists(dsym) {
                newCommandLine.append("-debug-symbols")
                newCommandLine.append(dsym.str)
            }
        }


        // If the '-archive' flag is used, then all -framework/-library usages will be prefixed with their corresponding path into the archive. Also, the '-headers' and '-debug-symbols' will be added pointing into the archive. This function does not handle any of the error handling, but lets the rest of the system deal with duplicate or improper usage.
        var newCommandLine: [String] = []

        var archiveRoot: Path?

        var entries = commandLine
        while !entries.isEmpty {
            let entry = entries.removeFirst()

            switch entry {
            case "-archive":
                archiveRoot = Path(entries.removeFirst()).makeAbsolute(relativeTo: currentWorkingDirectory)?.normalize()

            case "-framework":
                if let archiveRoot {
                    let name = entries.removeFirst()
                    newCommandLine.append("-framework")

                    let root = Path("Products/Library/Frameworks")
                    newCommandLine.append(archiveRoot.join(root).join(name).str)

                    rewriteDebugSymbolCommandLine(archiveRoot, name, fs, &newCommandLine)
                }
                else {
                    newCommandLine.append(entry)
                }

            case "-library":
                if let archiveRoot {
                    let name = entries.removeFirst()
                    newCommandLine.append("-library")

                    let root = Path("Products/usr/local/lib")
                    newCommandLine.append(archiveRoot.join(root).join(name).str)

                    let headers = archiveRoot.join("Products/usr/local/include")
                    if fs.exists(headers) {
                        newCommandLine.append("-headers")
                        newCommandLine.append(headers.str)
                    }

                    rewriteDebugSymbolCommandLine(archiveRoot, name, fs, &newCommandLine)
                }
                else {
                    newCommandLine.append(entry)
                }

            default:
                newCommandLine.append(entry)
            }

        }

        return newCommandLine
    }

    @_spi(Testing) public static func parseCommandLine(args commandLine: [String], currentWorkingDirectory: Path, fs: any FSProxy = PseudoFS()) -> Result<CommandLineParsingResult, XCFrameworkCreationError> {
        enum ParseState {
            case next
            case framework
            case library
            case libraryHeader
            case debugSymbols
            case output
            case end
        }

        // Determines if the current parse state is expecting additional command line arguments.
        func expectingAdditionalArguments(_ state: ParseState) -> Bool {
            switch state {
            case .framework: return true
            case .library: return true
            case .libraryHeader: return true
            case .output: return true
            case .debugSymbols: return true
            default: return false
            }
        }

        func normalize(path: String, cwd: Path) -> Path {
            precondition(cwd.isAbsolute)
            return Path(path).makeAbsolute(relativeTo: cwd)!.normalize()
        }

        precondition(currentWorkingDirectory.isAbsolute, "path '\(currentWorkingDirectory.str)' is not absolute")

        // The -archive flag is handled in a very special way; it re-writes the user's entered command line by emitting the corresponding -framework/-library, -headers, -debug-symbols arguments.
        let commandLine = rewriteCommandLine(commandLine, cwd: currentWorkingDirectory, fs:  fs)

        var arguments = [Argument]()
        var argumentIndex = commandLine.startIndex
        var parseState = ParseState.next
        var allowInternalDistribution = false

        while parseState != .end {
            guard argumentIndex != commandLine.endIndex else {
                guard !expectingAdditionalArguments(parseState) else {
                    return .failure(XCFrameworkCreationError(message: "error: expected parameter to argument."))
                }

                // Exit the parsing loop. Do NOT simply return as there are additional validations that happen later.
                parseState = .end
                continue
            }

            let arg = commandLine[argumentIndex]

            // If help is requested, simply show it and stop the command line argument processing.
            if arg == "-help" {
                return .success(.help)
            }

            switch parseState {
            case .next:
                switch arg {
                case "createXCFramework": parseState = .next        // the main command from Swift Build
                case "-create-xcframework": parseState = .next      // passed through via xcodebuild's parameter passing splat
                case "-framework": parseState = .framework
                case "-library": parseState = .library
                case "-headers": parseState = .libraryHeader
                case "-debug-symbols": parseState = .debugSymbols
                case "-output": parseState = .output
                case "-allow-internal-distribution":
                    allowInternalDistribution = true
                    parseState = .next

                default:
                    // When running via `xcodebuild`, there are additional arguments passed that we want to safely ignore.
                    if arg.hasPrefix("-DVT") || arg.hasPrefix("-ExtraPlugInFolders") {
                        parseState = .next
                    }
                    else {
                        return .failure(XCFrameworkCreationError(message: "error: invalid argument '\(arg)'."))
                    }
                }

            case .framework:
                arguments.append(.framework(path: normalize(path: arg, cwd: currentWorkingDirectory), debugSymbolPaths: []))
                parseState = .next

            case .library:
                arguments.append(.library(path: normalize(path: arg, cwd: currentWorkingDirectory), headersPath: nil, debugSymbolPaths: []))
                parseState = .next

            case .libraryHeader:
                let lastArgument = arguments.last
                guard let path = lastArgument?.libraryPath else {
                    return .failure(XCFrameworkCreationError(message: "error: headers are only allowed with the use of '-library'."))
                }

                arguments.removeLast()
                arguments.append(.library(path: path, headersPath: normalize(path: arg, cwd: currentWorkingDirectory), debugSymbolPaths: lastArgument?.debugSymbolPaths ?? []))
                parseState = .next

            case .debugSymbols:
                let debugSymbolPath = Path(arg)

                // This is a little-bit hacky, but it is what it is.
                switch arguments.last {
                case let .framework(path, debugSymbolPaths):
                    arguments.removeLast()
                    arguments.append(.framework(path: path, debugSymbolPaths: debugSymbolPaths + [debugSymbolPath]))
                case let .library(path, headersPath, debugSymbolPaths):
                    arguments.removeLast()
                    arguments.append(.library(path: path, headersPath: headersPath, debugSymbolPaths: debugSymbolPaths + [debugSymbolPath]))
                default:
                    return .failure(XCFrameworkCreationError(message: "error: debug symbols can only be specified using '-framework' or '-library'."))
                }

                parseState = .next

            case .output:
                guard arg.hasSuffix(".xcframework") else {
                    return .failure(XCFrameworkCreationError(message: "error: the output path must end with the extension 'xcframework'."))
                }
                arguments.append(.output(path: normalize(path: arg, cwd: currentWorkingDirectory)))
                parseState = .next

            case .end: break   // do nothing
            }

            // Time to grab the next index.
            argumentIndex += 1
        }

        let (frameworkCount, libraryCount, outputCount) = arguments.reduce((0, 0, 0)) { (acc, arg) in
            switch arg {
            case .framework(_,_): return (acc.0 + 1, acc.1, acc.2)
            case .library(_,_,_): return (acc.0, acc.1 + 1, acc.2)
            case .output(_): return (acc.0, acc.1, acc.2 + 1)
            case .internalDistribution: return acc
            }
        }

        if frameworkCount == 0 && libraryCount == 0 {
            return .failure(XCFrameworkCreationError(message: "error: at least one framework or library must be specified."))
        }

        if frameworkCount != 0 && libraryCount != 0 {
            return .failure(XCFrameworkCreationError(message: "error: an xcframework cannot contain both frameworks and libraries."))
        }

        if outputCount == 0 {
            return .failure(XCFrameworkCreationError(message: "error: no output was specified."))
        }

        if outputCount > 1 {
            return .failure(XCFrameworkCreationError(message: "error: only a single output location may be specified."))
        }

        return .success(.arguments(arguments, allowInternalDistribution: allowInternalDistribution))
    }

    @_spi(Testing) public static func framework(from path: Path, debugSymbolPaths: [Path] = [], fs: any FSProxy = localFS, infoLookup: any PlatformInfoLookup) -> Result<XCFramework.Library, XCFrameworkCreationError> {
        // On macOS this is actually the path to the symlink to the real binary.  It gets resolved in the funnel method libraryInfo(libPath:...).
        let binaryPath = path.join(path.basenameWithoutSuffix)
        return libraryInfo(libPath: path, binaryPath: binaryPath, headersPath: nil, debugSymbolPaths: debugSymbolPaths, fs: fs, infoLookup: infoLookup)
    }

    @_spi(Testing) public static func library(from path: Path, headersPath: Path?, debugSymbolPaths: [Path] = [], fs: any FSProxy = localFS, infoLookup: any PlatformInfoLookup) -> Result<XCFramework.Library, XCFrameworkCreationError> {
        // Headers are always put into the "Headers" folder. Note that the incoming parameter for headersPath is only used to determine if we are processing headers.
        let headersPath = headersPath.flatMap { _ in Path("Headers") }

        return libraryInfo(libPath: path, binaryPath: path, headersPath: headersPath, debugSymbolPaths: debugSymbolPaths, fs: fs, infoLookup: infoLookup)
    }

    static func libraryInfo(libPath: Path, binaryPath: Path, headersPath: Path?, debugSymbolPaths: [Path], fs: any FSProxy, infoLookup: any PlatformInfoLookup) -> Result<XCFramework.Library, XCFrameworkCreationError> {
        func sanitizedEnvironmentName(_ str: String) -> String {
            if str == "macabi" {
                return "maccatalyst"
            }

            return str
        }

        guard let file = try? fs.read(binaryPath) else {
            return .failure(XCFrameworkCreationError(message: "error: unable to read the file at '\(binaryPath.str)'"))
        }

        guard let machO = try? MachO(data: file) else {
            return .failure(XCFrameworkCreationError(message: "error: unable to create a Mach-O from the binary at '\(binaryPath.str)'"))
        }

        // Compute the relative path to the binary.
        // We resolve symlinks here because we want to seamlessly handle macOS framework structure, which involves multiple symlinks.  But that means we also have to resolve symlinks in the library path, because the path might start with /tmp (which will resolve to /private/tmp).  This should be fine since the ultimate product is a relative path, as Path.relativeSubpath() requires that one path be a subpath of the other.
        guard let resolvedBinaryPath = try? binaryPath.resolveSymlink(fs: fs) else {
            return .failure(XCFrameworkCreationError(message: "error: unable to resolve symbolic links to binary at '\(binaryPath.str)'"))
        }
        guard let resolvedLibPath = try? libPath.resolveSymlink(fs: fs) else {
            return .failure(XCFrameworkCreationError(message: "error: unable to resolve symbolic links to library at '\(libPath.str)'"))
        }
        guard let relativeBinaryPath = resolvedBinaryPath.relativeSubpath(from: resolvedLibPath.dirname).flatMap({ Path($0) }) else {
            return .failure(XCFrameworkCreationError(message: "error: cannot compute path of binary '\(resolvedBinaryPath.str)' relative to that of '\(resolvedLibPath.str)'"))
        }

        // IMPORTANT!! There is a serialization contract here between the creation of xcframeworks and the consumption of xcframeworks within the product. This serialization ***MUST*** go through the BuildVersion.Platform code.

        var supportedPlatform: String? = nil
        var supportedEnvironment: String? = nil

        let slices: [MachO.Slice]
        do {
            slices = try machO.slices()
        } catch {
            return .failure(XCFrameworkCreationError(message: "error: unable to find any architecture information in the binary at '\(binaryPath.str)': \(error)"))
        }

        let supportedArchs = OrderedSet(slices.sorted(by: \.arch).map(\.arch))

        var mergeableMetadataArchs = Set<String>()
        do {
            for slice in slices {
                if try slice.containsAtomInfo() {
                    mergeableMetadataArchs.insert(slice.arch)
                }
            }
        }
        catch {
            return .failure(XCFrameworkCreationError(message: "error: unable to determine mergeability of the binary at '\(binaryPath.str)': \(error)"))
        }
        if !mergeableMetadataArchs.isEmpty, Set(supportedArchs) != mergeableMetadataArchs {
            let unmergeableArchs = supportedArchs.subtracting(mergeableMetadataArchs)
            return .failure(XCFrameworkCreationError(message: "error: some archs in binary are mergeable, but others (\(unmergeableArchs.elements.joined(separator: ", ")) are not: '\(binaryPath.str)'"))
        }
        let containsMergeableMetadata = !mergeableMetadataArchs.isEmpty

        guard let platforms = try? Set(slices.flatMap { try $0.buildVersions() }.map(\.platform)) else {
            return .failure(XCFrameworkCreationError(message: "error: unable to find any specific architecture information in the binary at '\(binaryPath.str)'"))
        }

        if let platform = platforms.only {
            guard let platformInfoProvider = infoLookup.lookupPlatformInfo(platform: platform) else {
                return .failure(XCFrameworkCreationError(message: "error: unknown Mach-O platform ID '\(platform.rawValue)'"))
            }

            supportedPlatform = platformInfoProvider.llvmTargetTripleSys
            supportedEnvironment = platformInfoProvider.llvmTargetTripleEnvironment
        } else if !platforms.isEmpty {
            // This guards against the slices() containing different platforms.
            return .failure(XCFrameworkCreationError(message: "error: binaries with multiple platforms are not supported '\(binaryPath.str)'"))
        }

        guard let resolvedSupportedPlatform = supportedPlatform else {
            return .failure(XCFrameworkCreationError(message: "error: unable to determine the platform for the given binary '\(binaryPath.str)'; check your deployment version settings"))
        }

        let environmentIdentifier: String = supportedEnvironment.flatMap({ $0.isEmpty ? "" : "-\(sanitizedEnvironmentName($0))" }) ?? ""
        let libraryIdentifier = "\(resolvedSupportedPlatform)-\(supportedArchs.joined(separator: "_"))\(environmentIdentifier)"

        // There are two types of debugging symbols to concern ourselves with: dSYMs and BCSymbolMaps. Both are passed in via the commandline using the -debug-symbols flag. However, within the XCFramework itself, we store these in the same way that an xcarchive does, in a dSYMs and BCSymbolMaps folders.
        let debugSymbolsPath = debugSymbolPaths.contains { $0.fileExtension == "dSYM" } ? Path("dSYMs") : nil

        return .success(XCFramework.Library(libraryIdentifier: libraryIdentifier, supportedPlatform: resolvedSupportedPlatform, supportedArchitectures: supportedArchs, platformVariant: supportedEnvironment, libraryPath: Path(libPath.basename), binaryPath: relativeBinaryPath, headersPath: headersPath, debugSymbolsPath: debugSymbolsPath, mergeableMetadata: containsMergeableMetadata))
    }

    /// A key that holds the primary paths for xcframework contents.
    struct LibraryPathsKey: Hashable {
        /// The absolute path to the library.
        let libraryPath: Path

        /// The absolute path to the headers folder, if any.
        let headersPath: Path?

        /// The absolute path to various debug symbols, if any.
        let debugSymbolPaths: [Path]
    }

    /// This is the entry point from `xcodebuild -create-xcframework` for creating an xcframework from the CLI.
    public static func createXCFramework(commandLine: [String], currentWorkingDirectory: Path, infoLookup: any PlatformInfoLookup) -> (Bool, String) {

        let fs = localFS

        // Utility function for constructing the array of `XCFramework.Library` based on the command line arguments. A mapping of the path and the resulting library is returned upon success.
        func xcframeworkLibraries(from arguments: [Argument]) -> Result<[LibraryPathsKey:XCFramework.Library], XCFrameworkCreationError> {
            var libraryMap = [LibraryPathsKey:XCFramework.Library]()

            do {
                for arg in arguments {
                    switch arg {
                    case let .framework(path, debugSymbolPaths):
                        if !fs.exists(path) {
                            return .failure(XCFrameworkCreationError(message: "error: the path does not point to a valid framework: \(path.str)"))
                        }

                        for debugSymbolPath in debugSymbolPaths where !fs.exists(debugSymbolPath) {
                            return .failure(XCFrameworkCreationError(message: "error: the path does not point to a valid debug symbols file: \(debugSymbolPath.str)"))
                        }

                        let key = LibraryPathsKey(libraryPath: path, headersPath: nil, debugSymbolPaths: debugSymbolPaths)
                        libraryMap[key] = try framework(from: path, debugSymbolPaths: debugSymbolPaths, infoLookup: infoLookup).get()

                    case let .library(path, headersPath, debugSymbolPaths):
                        if !fs.exists(path) {
                            return .failure(XCFrameworkCreationError(message: "error: the path does not point to a valid library: \(path.str)"))
                        }

                        if let headersPath, !fs.exists(headersPath) {
                            return .failure(XCFrameworkCreationError(message: "error: the path does not point to a valid headers location: \(headersPath.str)"))
                        }

                        for debugSymbolPath in debugSymbolPaths where !fs.exists(debugSymbolPath) {
                            return .failure(XCFrameworkCreationError(message: "error: the path does not point to a valid debug symbols file: \(debugSymbolPath.str)"))
                        }

                        let key = LibraryPathsKey(libraryPath: path, headersPath: headersPath, debugSymbolPaths: debugSymbolPaths)
                        libraryMap[key] = try library(from: path, headersPath: headersPath, debugSymbolPaths: debugSymbolPaths, infoLookup: infoLookup).get()

                    default: continue
                    }
                }
            }
            catch {
                return .failure(XCFrameworkCreationError(message: error.localizedDescription))
            }

            return .success(libraryMap)
        }

        do {
            let parsedCommandLineArgs: [Argument]
            let allowInternalDistribution: Bool
            switch try parseCommandLine(args: commandLine, currentWorkingDirectory: currentWorkingDirectory, fs: fs).get() {
            case let .arguments(arguments, internalDistribution):
                parsedCommandLineArgs = arguments
                allowInternalDistribution = internalDistribution
            case .help:
                return (true, XCFramework.usage() + "\n")
            }

            let libraryMap = try xcframeworkLibraries(from: parsedCommandLineArgs).get()

            let xcframework = try XCFramework(libraries: libraryMap.values.map { $0 })

            guard let outputPath = parsedCommandLineArgs.filter({
                if case .output(_) = $0 { return true }
                return false
            }).first?.outputPath else {
                // this is a fatalError() as `parseCommandLine` should have already handled this error.
                fatalError("no output path found.")
            }

            try fs.createDirectory(outputPath, recursive: true)

            let bytes = ByteString(try xcframework.serialize())
            try fs.write(outputPath.join("Info.plist"), contents: bytes)

            for (path, library) in libraryMap {
                // Before doing anything, it's important to validate the library is properly configured for distribution.
                if !allowInternalDistribution {
                    try validateLibraryForDistribution(library, at: path)
                }

                // Create the library container.
                let libraryIdentifierPath = outputPath.join(library.libraryIdentifier)
                try fs.createDirectory(libraryIdentifierPath, recursive: true)

                // Copy over the actual library file.
                let destinationPath = libraryIdentifierPath.join(library.libraryPath)
                try fs.createDirectory(destinationPath.dirname, recursive: true)
                try fs.copy(path.libraryPath, to: destinationPath)

                // Process any headers.
                if let headersPath = library.headersPath {
                    let destinationPath = libraryIdentifierPath.join(headersPath)
                    try fs.createDirectory(destinationPath.dirname, recursive: true)
                    try fs.copy(path.headersPath!, to: destinationPath)
                }

                // Process the debug symbols, if any.
                if let debugSymbolsPath = library.debugSymbolsPath {
                    for pathToDSYM in path.debugSymbolPaths.filter({ $0.fileExtension == "dSYM" }) {
                        let destinationPath = libraryIdentifierPath.join(debugSymbolsPath).join(pathToDSYM.basename)
                        try fs.createDirectory(destinationPath.dirname, recursive: true)
                        try fs.copy(pathToDSYM, to: destinationPath)
                    }
                }

                // If there are any of the special Swift files, pick these up to.
                let libraryName = library.libraryPath.basenameWithoutSuffix
                let baseLibraryName = libraryName.hasPrefix("lib") ? libraryName.withoutPrefix("lib") : libraryName
                for file in try fs.listdir(path.libraryPath.dirname) {
                    let filePath = path.libraryPath.dirname.join(file)
                    // Libraries typically have the the prefix "lib" in the name. Also, we should only copy over items that are matching, so we look for a swift file that has a match without the lib prefix.
                    let swiftExtensions = ["swiftinterface", "swiftmodule", "swiftdoc"]
                    if baseLibraryName == filePath.basenameWithoutSuffix && swiftExtensions.contains(filePath.fileExtension) {
                        try fs.copy(filePath, to: libraryIdentifierPath.join(file))
                    }
                }
            }

            if !allowInternalDistribution {
                try removeSwiftModuleFiles(from: outputPath)
            }

            return (true, "xcframework successfully written out to: \(outputPath.str)\n")
        }
        catch {
            return (false, "\(error.localizedDescription)\n")
        }
    }

    /// Performs validation of the given input to ensure that the built library is configured for distribution.
    private static func validateLibraryForDistribution(_ library: Library, at basePath: LibraryPathsKey) throws {
        // The current behavior is to check for the presence of `swiftinterface` files as only the Swift compiler supports the "Build Libraries for Distribution" build setting. In the future, any additional checks should be added here as tools add support for that build setting.

        var name = library.libraryPath.basenameWithoutSuffix
        if name.hasPrefix("lib") { name.removeFirst(3) }
        let swiftModuleFolder = Path("\(name).swiftmodule")

        let moduleFolderPath: Path?
        switch library.libraryType {
        case .framework:
            moduleFolderPath = basePath.libraryPath.join("Modules").join(swiftModuleFolder)
        case .dynamicLibrary, .staticLibrary:
            // NOTE: It's acceptable to have no headers path, which will cause validation to be skipped.
            moduleFolderPath = basePath.headersPath?.join(swiftModuleFolder)

        default:
            moduleFolderPath = nil
        }

        // Validation should only be considered if a Swift module folder structure is present.
        // TODO: Consider allowing flat layout for swiftmodule/swiftinterface files. (rdar://51674808)
        guard let path = moduleFolderPath, localFS.exists(path), localFS.isDirectory(path) else { return }

        let files = try localFS.listdir(path)
        let hasSwiftInterface = files.contains { $0.hasSuffix("swiftinterface") }
        if !hasSwiftInterface {
            throw XCFrameworkCreationError(message: "No 'swiftinterface' files found within '\(moduleFolderPath?.str ?? basePath.libraryPath.str)'.")
        }
    }

    /// Removes any `swiftmodule` files found within the given path.
    private static func removeSwiftModuleFiles(from path: Path) throws {
        try localFS.traverse(path) { path in
            if path.fileSuffix == ".swiftmodule" && !localFS.isDirectory(path) {
                try localFS.remove(path)
            }
        }
    }
}

extension XCFramework {
    @discardableResult public func copy(library: XCFramework.Library, from xcframeworkPath: Path, to targetPath: Path, fs: any FSProxy, dryRun: Bool = false) throws -> [Path] {
        var outputPaths = [Path]()
        func copy(_ src: Path, to dst: Path) throws {
            // FIXME: Support nested filtering as well so we can filter things like `.git/**`. (rdar://81236853)
            if src.basename == ".DS_Store" { return }

            outputPaths.append(dst)
            if fs.isDirectory(src) {
                try fs.traverse(src) { p in
                    outputPaths.append(dst.join(p.relativeSubpath(from: src)))
                }
            }

            if !dryRun {
                struct Static {
                    static let lock = SWBMutex(())
                }

                // Use a lock in order to reduce non-determinism when multiple ProcessXCFramework tasks produce the same outputs.
                // This is an error and will be diagnosed as such separately by llbuild.
                try Static.lock.withLock {
                    if fs.isDirectory(dst) {
                        try fs.removeDirectory(dst)
                    } else if fs.exists(dst) {
                        try fs.remove(dst)
                    }
                    try fs.copy(src, to: dst)
                }
            }
        }

        let rootPathToLibrary = xcframeworkPath.join(library.libraryIdentifier)
        let copyLibraryFromPath = rootPathToLibrary.join(library.libraryPath)

        let copyLibraryToPath = targetPath
        let libraryTargetPath = copyLibraryToPath.join(library.libraryPath)

        // Ensure the framework/dylib target directory exists on disk.
        if !dryRun {
            try fs.createDirectory(copyLibraryToPath, recursive: true)
        }

        // Copy over the framework or dylib.
        try copy(copyLibraryFromPath, to: libraryTargetPath)

        // Copy over any debug symbols that may exist.
        if let debugSymbolsPath = library.debugSymbolsPath {
            let copyDebugSymbolsFromPath = rootPathToLibrary.join(debugSymbolsPath)
            guard fs.exists(copyDebugSymbolsFromPath) else {
                throw XCFrameworkValidationError.missingPathEntry(xcframeworkPath: xcframeworkPath, libraryIdentifier: library.libraryIdentifier, plistKey: XCFrameworkInfoPlist_V1.Library.CodingKeys.debugSymbolsPath.stringValue, plistValue: library.debugSymbolsPath?.str ?? "<empty value>")
            }
            let copyDebugSymbolsToPath = copyLibraryToPath
            for file in try fs.listdir(copyDebugSymbolsFromPath) {
                try copy(copyDebugSymbolsFromPath.join(file), to: copyDebugSymbolsToPath.join(file))
            }
        }

        // If the library has headers, we need to create a task to copy those over as well.
        if let headersPath = library.headersPath, library.libraryType.canHaveHeaders {
            let copyHeadersFromPath = rootPathToLibrary.join(headersPath)
            guard fs.exists(copyHeadersFromPath) else {
                throw XCFrameworkValidationError.missingPathEntry(xcframeworkPath: xcframeworkPath, libraryIdentifier: library.libraryIdentifier, plistKey: XCFrameworkInfoPlist_V1.Library.CodingKeys.headersPath.stringValue, plistValue: library.headersPath?.str ?? "<empty value>")
            }
            let copyHeadersToPath = copyLibraryToPath.join(Path("include"))     // this is the path that is added by default from the compile process.

            // Ensure the headers path actually exists on disk.
            if !dryRun {
                try fs.createDirectory(copyHeadersToPath, recursive: true)
            }

            // A copy task needs to be created for each of the items within the "Headers" folder as we don't want the "Headers" actually in the resulting path.
            try fs.traverse(copyHeadersFromPath) { fromPath in
                if !fs.isDirectory(fromPath) {
                    try copy(fromPath, to: copyHeadersToPath.join(fromPath.relativeSubpath(from: copyHeadersFromPath)))
                }
            }
        }

        // For dynamic and static libraries, the swift modules and interface files live as siblings to the library itself. These need to be copied here specially.
        if library.libraryType == .dynamicLibrary || library.libraryType == .staticLibrary {
            for file in try fs.listdir(rootPathToLibrary) {
                let filePath = rootPathToLibrary.join(file)

                // A dictionary of the interesting swift extensions with a corresponding label to give the task.
                let swiftExtensions = ["swiftinterface", "swiftmodule", "swiftdoc"]
                if swiftExtensions.contains(filePath.fileExtension) {
                    let destinationPath = copyLibraryToPath.join(file)
                    try copy(filePath, to: destinationPath)
                }
            }
        }

        return Set(outputPaths).sorted()
    }
}
