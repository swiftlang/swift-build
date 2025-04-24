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
import SWBMacro

@_spi(Testing) import SWBCore

@Suite fileprivate struct XCFrameworkTests {

    let defaultVersion = Version(1)

    fileprivate func assertValidationError(libraries: OrderedSet<XCFramework.Library>, sourceLocation: SourceLocation = #_sourceLocation, handler: (any Error) -> Void) {
        assertValidationError(version: defaultVersion, libraries: libraries, sourceLocation: sourceLocation, handler: handler)
    }

    fileprivate func assertValidationError(version: Version, libraries: OrderedSet<XCFramework.Library>, sourceLocation: SourceLocation = #_sourceLocation, handler: (any Error) -> Void) {
        do {
            let _ = try XCFramework(version: version, libraries: libraries)
            Issue.record("Expected a validation error.", sourceLocation: sourceLocation)
        }
        catch {
            handler(error)
        }
    }

    fileprivate func assertValidationError(libraries: [XCFramework.Library], sourceLocation: SourceLocation = #_sourceLocation, handler: (any Error) -> Void) {
        assertValidationError(version: defaultVersion, libraries: libraries, sourceLocation: sourceLocation, handler: handler)
    }

    fileprivate func assertValidationError(version: Version, libraries: [XCFramework.Library], sourceLocation: SourceLocation = #_sourceLocation, handler: (any Error) -> Void) {
        do {
            let _ = try XCFramework(version: version, libraries: libraries)
            Issue.record("Expected a validation error.", sourceLocation: sourceLocation)
        }
        catch {
            handler(error)
        }
    }

    @Test
    func XCFrameworkValidationErrors() throws {
        do {
            let version = Version(12, 0)
            let libraries = OrderedSet<XCFramework.Library>()

            assertValidationError(version: version, libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.unsupportedVersion(version): #expect(version == "12.0")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries = OrderedSet<XCFramework.Library>()

            assertValidationError(libraries: libraries) { error in
                switch error {
                case XCFrameworkValidationError.noLibraries: break
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries: OrderedSet<XCFramework.Library> = [
                XCFramework.Library(libraryIdentifier: "foo", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Foo.unsupported"), binaryPath: Path("Foo.unsupported"), headersPath: nil),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.unsupportedLibraryType(libraryType, libraryIdentifier):
                    #expect(libraryType == XCFramework.LibraryType.unknown(fileExtension: "unsupported"))
                    #expect(libraryIdentifier == "foo")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries: OrderedSet<XCFramework.Library> = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libtest.dylib"), binaryPath: Path("libtest.dylib"), headersPath: Path("Headers")),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.mixedLibraryTypes(libraryType, otherLibraryType):
                    #expect(libraryType == XCFramework.LibraryType.staticLibrary)
                    #expect(otherLibraryType == XCFramework.LibraryType.dynamicLibrary)
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries: OrderedSet<XCFramework.Library> = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.supportedPlatformEmpty(libraryIdentifier):
                    #expect(libraryIdentifier == "arm64-apple-iphoneos13.0")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries: OrderedSet<XCFramework.Library> = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("")),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.headersPathEmpty(libraryIdentifier):
                    #expect(libraryIdentifier == "arm64-apple-iphoneos13.0")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries: OrderedSet<XCFramework.Library> = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
                XCFramework.Library(libraryIdentifier: "i386-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["i386"], platformVariant: nil, libraryPath: Path("foo.a"), binaryPath: Path("foo.a"), headersPath: Path("MyHeaders")),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.conflictingLibraryDefinitions(libraryIdentifier, otherLibraryIdentifier):
                    #expect(libraryIdentifier == "x86_64-apple-macos10.15")
                    #expect(otherLibraryIdentifier == "i386-apple-macos10.15")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
                XCFramework.Library(libraryIdentifier: "i386-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["i386"], platformVariant: nil, libraryPath: Path("foo.a"), binaryPath: Path("foo.a"), headersPath: Path("MyHeaders")),
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.duplicateLibraryIdentifier(libraryIdentifier):
                    #expect(libraryIdentifier == "x86_64-apple-macos10.15")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("foo.framework"), binaryPath: Path("foo.framework/Versions/A/foo"), headersPath: Path("Headers")),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.headerPathNotSupported(libraryType, libraryIdentifier):
                    #expect(libraryType == .framework)
                    #expect(libraryIdentifier == "x86_64-apple-macos10.15")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries = [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers"), mergeableMetadata: true),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.libraryTypeDoesNotSupportMergeableMetadata(libraryType):
                    #expect(libraryType == .staticLibrary)
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let libraries: OrderedSet<XCFramework.Library> = [
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libtest.dylib"), binaryPath: nil, headersPath: Path("Headers"), mergeableMetadata: true),
            ]

            assertValidationError(libraries: libraries) { error in
                switch error {
                case let XCFrameworkValidationError.mergeableLibraryBinaryPathEmpty(libraryIdentifier):
                    #expect(libraryIdentifier == "arm64-apple-iphoneos13.0")
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }

        do {
            let fs = PseudoFS()
            let _ = try XCFramework(path: Path.root.join("tmp/no.xcframework"), fs: fs)
            Issue.record("should have failed loading xcframework")
        }
        catch let XCFrameworkValidationError.missingXCFramework(path) {
            #expect(path.str == Path.root.join("tmp/no.xcframework").str)
        }
        catch {
            Issue.record("unexpected error: \(error)")
        }

        do {
            let fs = PseudoFS()
            let xcframeworkPath = Path.root.join("tmp/foo.xcframework")
            try fs.createDirectory(xcframeworkPath, recursive: true)
            let _ = try XCFramework(path: xcframeworkPath, fs: fs)
            Issue.record("should have failed loading xcframework")
        }
        catch let XCFrameworkValidationError.missingInfoPlist(path) {
            #expect(path.str == Path.root.join("tmp/foo.xcframework/Info.plist").str)
        }
        catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func findingXCFrameworkLibrary() throws {
        let version = Version(1, 0)
        let libraries: OrderedSet<XCFramework.Library> = [
            XCFramework.Library(libraryIdentifier: "lib1", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
            XCFramework.Library(libraryIdentifier: "lib2", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: "var1", libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
            XCFramework.Library(libraryIdentifier: "lib3", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: "var2", libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
            XCFramework.Library(libraryIdentifier: "lib4", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
            XCFramework.Library(libraryIdentifier: "lib5", supportedPlatform: "driverkit", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libtest.a"), binaryPath: Path("libtest.a"), headersPath: Path("Headers")),
        ]

        let xcframework = try XCFramework(version: version, libraries: libraries)
        #expect(xcframework.findLibrary(platform: "macos")?.libraryIdentifier == "lib1")
        #expect(xcframework.findLibrary(platform: "macos", platformVariant: "var1")?.libraryIdentifier == "lib2")
        #expect(xcframework.findLibrary(platform: "ios", platformVariant: "var2")?.libraryIdentifier == "lib3")
        #expect(xcframework.findLibrary(platform: "ios")?.libraryIdentifier == "lib4")
        #expect(xcframework.findLibrary(platform: "missing")?.libraryIdentifier == nil)
        #expect(xcframework.findLibrary(platform: "ios", platformVariant: "missing")?.libraryIdentifier == nil)
        #expect(xcframework.findLibrary(platform: "macos", platformVariant: "")?.libraryIdentifier == "lib1")
        #expect(xcframework.findLibrary(platform: "driverkit", platformVariant: "")?.libraryIdentifier == "lib5")
    }
}

@Suite fileprivate struct XCFrameworkInfoPlistv1ParsingTests {

    func assertParsingError(plist: PropertyListItem, message expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let _ = try XCFramework(other: try PropertyList.decode(XCFrameworkInfoPlist_V1.self, from: plist))

            Issue.record("expected XCFrameworkError.parsing", sourceLocation: sourceLocation)
        }
        catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription == expected)
        }
        catch DecodingError.valueNotFound(_, let context) {
            #expect(context.debugDescription == expected)
        }
        catch DecodingError.keyNotFound(_, let context) {
            #expect(context.debugDescription == expected)
        }
        catch DecodingError.typeMismatch(_, let context) {
            #expect(context.debugDescription == expected)
        }
        catch {
            Issue.record("unexpected error throw: \(error)", sourceLocation: sourceLocation)
        }
    }

    func assertValidationError(plist: PropertyListItem, error expected: XCFrameworkValidationError, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let _ = try XCFramework(other: try PropertyList.decode(XCFrameworkInfoPlist_V1.self, from: plist))

            Issue.record("expected XCFrameworkError.parsing", sourceLocation: sourceLocation)
        }
        catch let validationError as XCFrameworkValidationError {
            #expect(validationError == expected)
        }
        catch {
            Issue.record("unexpected error throw: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test
    func parseWithNoErrors() throws {
        let plist: PropertyListItem = .plDict([
            "XCFrameworkFormatVersion": .plString("1.0"),
            "AvailableLibraries": .plArray([
                .plDict([
                    "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                    "SupportedPlatform": .plString("macosx"),
                    "SupportedArchitectures": .plArray([.plString("x86_64")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    "BinaryPath": .plString("XCSample.dylib"),
                    "HeadersPath": .plString("Headers"),
                    "DebugSymbolsPath": .plString("dSYMs"),
                    "SupportedPlatformVariant": .plString("maccatalyst")
                ]),
                .plDict([
                    "LibraryIdentifier": .plString("arm64-apple-iphoneos13.0"),
                    "SupportedPlatform": .plString("iphoneos"),
                    "SupportedArchitectures": .plArray([.plString("arm64"), .plString("arm64e")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    "BinaryPath": .plString("XCSample.dylib"),
                    "HeadersPath": .plString("Headers"),
                ]),
                .plDict([
                    "LibraryIdentifier": .plString("x86_64-apple-iphonesimulator13.0"),
                    "SupportedPlatform": .plString("iphonesimulator"),
                    "SupportedArchitectures": .plArray([.plString("x86_64")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    // Missing BinaryPath to exercise this case
                    "HeadersPath": .plString("Headers"),
                ]),
            ])
        ])

        let xcframework: XCFramework
        do {
            xcframework = try XCFramework(other: try PropertyList.decode(XCFrameworkInfoPlist_V1.self, from: plist))
        } catch {
            Issue.record("Could not load XCFramework: \(error.localizedDescription)")
            return
        }

        #expect(xcframework.version == Version(1, 0))
        #expect(xcframework.libraries.count == 3)

        do {
            let library = xcframework.libraries.first { $0.libraryIdentifier == "x86_64-apple-macos10.15" }!
            #expect(library.supportedPlatform == "macosx")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.libraryPath.str == "XCSample.dylib")
            #expect(library.binaryPath?.str == "XCSample.dylib")
            #expect(library.headersPath?.str == "Headers")
            #expect(library.debugSymbolsPath?.str == "dSYMs")
            #expect(library.platformVariant == "macabi")
        }

        do {
            let library = xcframework.libraries.first { $0.libraryIdentifier == "arm64-apple-iphoneos13.0" }!
            #expect(library.supportedPlatform == "iphoneos")
            #expect(library.supportedArchitectures == ["arm64", "arm64e"])
            #expect(library.libraryPath.str == "XCSample.dylib")
            #expect(library.binaryPath?.str == "XCSample.dylib")
            #expect(library.headersPath?.str == "Headers")
        }

        do {
            let library = xcframework.libraries.first { $0.libraryIdentifier == "x86_64-apple-iphonesimulator13.0" }!
            #expect(library.supportedPlatform == "iphonesimulator")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.libraryPath.str == "XCSample.dylib")
            #expect(library.binaryPath == nil)
            #expect(library.headersPath?.str == "Headers")
        }
    }

    @Test
    func XCFrameworkParsingErrors() throws {
        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("15.0"),
                "AvailableLibraries": .plDict([:])
            ])
            assertParsingError(plist: plist, message: "Expected to decode Array<Any> but found a dictionary instead.")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersionXXX": .plString("15.0"),
                "AvailableLibraries": .plArray([])
            ])

            assertParsingError(plist: plist, message: "No value associated with key CodingKeys(stringValue: \"XCFrameworkFormatVersion\", intValue: nil) (\"XCFrameworkFormatVersion\").")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("edf3djf"),
                "AvailableLibraries": .plArray([])
            ])

            assertValidationError(plist: plist, error: XCFrameworkValidationError.unsupportedVersion(version: "edf3djf"))
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plString("LibraryIdentifier"),
                    .plInt(12)
                ])
            ])

            // FIXME: This check should really be expressed in terms of "Swift < 6.0" or something
            if try (ProcessInfo.processInfo.hostOperatingSystem() == .macOS && ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15) {
                assertParsingError(plist: plist, message: "Expected to decode Dictionary<String, Any> but found a string/data instead.")
            } else {
                assertParsingError(plist: plist, message: "Expected to decode Dictionary<String, Any> but found a string instead.")
            }
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifierXXX": .plString("")
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "No value associated with key CodingKeys(stringValue: \"LibraryIdentifier\", intValue: nil) (\"LibraryIdentifier\").")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("")
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "No value associated with key CodingKeys(stringValue: \"SupportedPlatform\", intValue: nil) (\"SupportedPlatform\").")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plArray([])
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "Expected to decode String but found an array instead.")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plString("macosx"),
                        "SupportedArchitectures": .plString("")
                    ])
                ])
            ])

            // FIXME: This check should really be expressed in terms of "Swift < 6.0" or something
            if try (ProcessInfo.processInfo.hostOperatingSystem() == .macOS && ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15) {
                assertParsingError(plist: plist, message: "Expected to decode Array<Any> but found a string/data instead.")
            } else {
                assertParsingError(plist: plist, message: "Expected to decode Array<Any> but found a string instead.")
            }
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plString("macosx"),
                        "SupportedArchitectures": .plArray([.plDict([:])])
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "Expected to decode String but found a dictionary instead.")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plString("macosx"),
                        "SupportedArchitectures": .plArray([.plString("x86_64")])
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "No value associated with key CodingKeys(stringValue: \"LibraryPath\", intValue: nil) (\"LibraryPath\").")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plString("macosx"),
                        "SupportedArchitectures": .plArray([.plString("x86_64")]),
                        "LibraryPath": .plString("libtest.a"),
                        "HeadersPath": .plArray([])
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "Expected to decode String but found an array instead.")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plString("macosx"),
                        "SupportedArchitectures": .plArray([.plString("x86_64")]),
                        "LibraryPath": .plString("libtest.a"),
                        "HeadersPath": .plString("Headers"),
                        "DebugSymbolsPath": .plArray([])
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "Expected to decode String but found an array instead.")
        }

        do {
            let plist: PropertyListItem = .plDict([
                "XCFrameworkFormatVersion": .plString("1.0"),
                "AvailableLibraries": .plArray([
                    .plDict([
                        "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                        "SupportedPlatform": .plString("macosx"),
                        "SupportedArchitectures": .plArray([.plString("x86_64")]),
                        "LibraryPath": .plString("libtest.a"),
                        "HeadersPath": .plString("Headers"),
                        "DebugSymbolsPath": .plString("dSYMs"),
                        "SupportedPlatformVariant": .plArray([])
                    ])
                ])
            ])

            assertParsingError(plist: plist, message: "Expected to decode String but found an array instead.")
        }
    }

    @Test
    func roundTripEncoding() throws {
        let plist: PropertyListItem = .plDict([
            "XCFrameworkFormatVersion": .plString("1.0"),
            "AvailableLibraries": .plArray([
                .plDict([
                    "LibraryIdentifier": .plString("x86_64-apple-macos10.15"),
                    "SupportedPlatform": .plString("macosx"),
                    "SupportedArchitectures": .plArray([.plString("x86_64")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    "BinaryPath": .plString("XCSample.dylib"),
                    "HeadersPath": .plString("Headers"),
                    "DebugSymbolsPath": .plString("dSYMs"),
                    "SupportedPlatformVariant": .plString("maccatalyst")
                ]),
                .plDict([
                    "LibraryIdentifier": .plString("arm64-apple-iphoneos13.0"),
                    "SupportedPlatform": .plString("iphoneos"),
                    "SupportedArchitectures": .plArray([.plString("arm64"), .plString("arm64e")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    // BinaryPath missing to test this case
                    "HeadersPath": .plString("Headers")
                ]),
            ])
        ])

        func validate(_ xcframework: XCFramework) throws {
            #expect(xcframework.version == Version(1, 0))
            #expect(xcframework.libraries.count == 2)

            do {
                let library = xcframework.libraries.first { $0.libraryIdentifier == "x86_64-apple-macos10.15" }!
                #expect(library.supportedPlatform == "macosx")
                #expect(library.supportedArchitectures == ["x86_64"])
                #expect(library.libraryPath.str == "XCSample.dylib")
                #expect(library.binaryPath?.str == "XCSample.dylib")
                #expect(library.headersPath?.str == "Headers")
                #expect(library.debugSymbolsPath?.str == "dSYMs")
                #expect(library.platformVariant == "macabi")
            }

            do {
                let library = xcframework.libraries.first { $0.libraryIdentifier == "arm64-apple-iphoneos13.0" }!
                #expect(library.supportedPlatform == "iphoneos")
                #expect(library.supportedArchitectures == ["arm64", "arm64e"])
                #expect(library.libraryPath.str == "XCSample.dylib")
                #expect(library.binaryPath == nil)
                #expect(library.headersPath?.str == "Headers")
                #expect(library.debugSymbolsPath == nil)
            }
        }

        let xcframeworkInfoPlistV1: XCFrameworkInfoPlist_V1
        do {
            do {
                xcframeworkInfoPlistV1 = try PropertyList.decode(XCFrameworkInfoPlist_V1.self, from: plist)
            } catch {
                Issue.record("Could not decode Info.plist: \(error.localizedDescription)")
                return
            }
            let xcframework: XCFramework
            do {
                xcframework = try XCFramework(other: xcframeworkInfoPlistV1)
            } catch {
                Issue.record("Could not load XCFramework: \(error.localizedDescription)")
                return
            }
            try validate(xcframework)
        }

        do {
            let encodedData: Data
            do {
                encodedData = try PropertyListEncoder().encode(xcframeworkInfoPlistV1)
            } catch {
                Issue.record("Could not encode Info.plist: \(error.localizedDescription)")
                return
            }
            let xcframeworkInfoPlistV1RoundTrip: XCFrameworkInfoPlist_V1
            do {
                xcframeworkInfoPlistV1RoundTrip = try PropertyListDecoder().decode(XCFrameworkInfoPlist_V1.self, from: encodedData)
            } catch {
                Issue.record("Could not decode Info.plist: \(error.localizedDescription)")
                return
            }
            let xcframework: XCFramework
            do {
                xcframework = try XCFramework(other: xcframeworkInfoPlistV1RoundTrip)
            } catch {
                Issue.record("Could not load XCFramework: \(error.localizedDescription)")
                return
            }
            try validate(xcframework)
        }
    }

    @Test
    func valueSanitation() throws {
        let plist: PropertyListItem = .plDict([
            "XCFrameworkFormatVersion": .plString("1.0"),
            "AvailableLibraries": .plArray([
                .plDict([
                    "LibraryIdentifier": .plString("x86_64-apple-macos10.15-other"),
                    "SupportedPlatform": .plString("macosx_other"),
                    "SupportedArchitectures": .plArray([.plString("x86_64")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    "BinaryPath": .plString("XCSample.dylib"),
                    "HeadersPath": .plString("Headers"),
                    "SupportedPlatformVariant": .plString("macabi")
                ]),
                .plDict([
                    "LibraryIdentifier": .plString("x86_64-apple-macos10.15-another"),
                    "SupportedPlatform": .plString("macosx_another"),
                    "SupportedArchitectures": .plArray([.plString("x86_64")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    "BinaryPath": .plString("XCSample.dylib"),
                    "HeadersPath": .plString("Headers"),
                    "SupportedPlatformVariant": .plString("maccatalyst")
                ]),
                .plDict([
                    "LibraryIdentifier": .plString("x86_64-apple-macos10.15-nobinarypath"),
                    "SupportedPlatform": .plString("macosx_nobinarypath"),
                    "SupportedArchitectures": .plArray([.plString("x86_64")]),
                    "LibraryPath": .plString("XCSample.dylib"),
                    // No BinaryPath
                    "HeadersPath": .plString("Headers"),
                    "SupportedPlatformVariant": .plString("maccatalyst")
                ]),
            ])
        ])

        let xcframework: XCFramework
        do {
            xcframework = try XCFramework(other: try PropertyList.decode(XCFrameworkInfoPlist_V1.self, from: plist))
        } catch {
            Issue.record("Could not load XCFramework: \(error.localizedDescription)")
            return
        }

        #expect(xcframework.version == Version(1, 0))
        #expect(xcframework.libraries.count == 3)

        do {
            let library = xcframework.libraries.first { $0.libraryIdentifier == "x86_64-apple-macos10.15-other" }!
            #expect(library.supportedPlatform == "macosx_other")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.libraryPath.str == "XCSample.dylib")
            #expect(library.binaryPath?.str == "XCSample.dylib")
            #expect(library.headersPath?.str == "Headers")
            #expect(library.platformVariant == "macabi")
        }

        do {
            let library = xcframework.libraries.first { $0.libraryIdentifier == "x86_64-apple-macos10.15-another" }!
            #expect(library.supportedPlatform == "macosx_another")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.libraryPath.str == "XCSample.dylib")
            #expect(library.binaryPath?.str == "XCSample.dylib")
            #expect(library.headersPath?.str == "Headers")
            #expect(library.platformVariant == "macabi")
        }

        do {
            let library = xcframework.libraries.first { $0.libraryIdentifier == "x86_64-apple-macos10.15-nobinarypath" }!
            #expect(library.supportedPlatform == "macosx_nobinarypath")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.libraryPath.str == "XCSample.dylib")
            #expect(library.binaryPath == nil)
            #expect(library.headersPath?.str == "Headers")
            #expect(library.platformVariant == "macabi")
        }

        // Now validate that when we serialize the xcframework back out, we get the sanitized versions.
        let roundtripPlist = try PropertyList.fromBytes([UInt8](try xcframework.serialize()))
        let libraries = roundtripPlist.dictValue?["AvailableLibraries"]?.arrayValue ?? []
        #expect(libraries.count == 3)
        #expect(libraries[0].dictValue?["SupportedPlatformVariant"]?.stringValue == "maccatalyst")
        #expect(libraries[1].dictValue?["SupportedPlatformVariant"]?.stringValue == "maccatalyst")
        #expect(libraries[2].dictValue?["SupportedPlatformVariant"]?.stringValue == "maccatalyst")
    }
}

// MARK: XCFramework CLI Construction Tests

fileprivate extension Result where Success == XCFramework.CommandLineParsingResult, Failure == XCFrameworkCreationError {
    var arguments: [XCFramework.Argument]? {
        if case let .success(result) = self {
            switch result {
            case let .arguments(arguments, _):
                return arguments
            case .help:
                return nil
            }
        }
        return nil
    }

    var error: XCFrameworkCreationError? {
        if case let .failure(err) = self { return err }
        return nil
    }
}

fileprivate extension Result where Success == XCFramework.Library, Failure == XCFrameworkCreationError {
    var library: XCFramework.Library? {
        if case let .success(lib) = self { return lib }
        return nil
    }

    var error: XCFrameworkCreationError? {
        if case let .failure(err) = self { return err }
        return nil
    }
}


@Suite fileprivate struct XCFrameworkCreationParsingErrorsTests {

    @Test
    func invalidOutputName() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-output", "opath"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: the output path must end with the extension \'xcframework\'.") == true)
    }

    @Test
    func atLeastOneLibrary() {
        let commandLine = ["createXCFramework", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: at least one framework or library must be specified.") == true)
    }

    @Test
    func mixingLibraryTypes() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-library", "fpath2", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: an xcframework cannot contain both frameworks and libraries.") == true)
    }

    @Test
    func missingOutput() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-framework", "fpath2"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: no output was specified.") == true)
    }

    @Test
    func multipleOutputs() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-framework", "fpath2", "-output", "opath1.xcframework", "-output", "opath2.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: only a single output location may be specified.") == true)
    }

    @Test
    func missingArgument() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-framework", "fpath2", "-output"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: expected parameter to argument.") == true)
    }

    @Test
    func invalidArgument() {
        let commandLine = ["createXCFramework", "-frameworks", "fpath1", "-framework", "fpath2", "-output"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: invalid argument '-frameworks'.") == true)
    }

    @Test
    func invalidHeadersFlag() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-headers", "hpath1", "-output"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: headers are only allowed with the use of '-library'.") == true)
    }

    @Test
    func invalidHeadersFlagPosition() {
        let commandLine = ["createXCFramework", "-headers", "hpath1", "-library", "lpath1", "-output"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        #expect(result.error?.message.starts(with: "error: headers are only allowed with the use of '-library'.") == true)
    }
}

@Suite fileprivate struct XCFrameworkCreationParsingTests {
    @Test
    func xcodebuildInvocation() {
        let commandLine = ["createXCFramework", "-create-xcframework", "-framework", "fpath1", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.framework(path: Path.root.join("tmp/fpath1")), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

    @Test
    func singleFramework() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.framework(path: Path.root.join("tmp/fpath1")), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

    @Test
    func singleLibrary() {
        let commandLine = ["createXCFramework", "-library", "lpath1", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.library(path: Path.root.join("tmp/lpath1"), headersPath: nil), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

    @Test
    func singleLibraryWithHeaders() {
        let commandLine = ["createXCFramework", "-library", "lpath1", "-headers", "hpath1", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.library(path: Path.root.join("tmp/lpath1"), headersPath: Path.root.join("tmp/hpath1")), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

    @Test
    func multipleFrameworks() {
        let commandLine = ["createXCFramework", "-framework", "fpath1", "-framework", "fpath2", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.framework(path: Path.root.join("tmp/fpath1")), .framework(path: Path.root.join("tmp/fpath2")), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

    @Test
    func multipleLibrariesWithHeaders() {
        let commandLine = ["createXCFramework", "-library", "lpath1", "-headers", "hpath1", "-library", "lpath2", "-headers", "hpath2", "-output", "opath.xcframework"]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.library(path: Path.root.join("tmp/lpath1"), headersPath: Path.root.join("tmp/hpath1")), .library(path: Path.root.join("tmp/lpath2"), headersPath: Path.root.join("tmp/hpath2")), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

    @Test
    func relativeAndAbsolutePaths() {
        let commandLine = ["createXCFramework", "-library", Path.root.join("some/lpath1").str, "-headers", "../hpath1", "-library", "./lpath2", "-headers", "hpath2", "-output", Path.root.join("tmp/../tmp/foo/../opath.xcframework").str]
        let result = XCFramework.parseCommandLine(args: commandLine, currentWorkingDirectory: Path.root.join("tmp"))
        guard let arguments = result.arguments else {
            Issue.record(Comment(rawValue: result.error!.message))
            return
        }

        let expected: [XCFramework.Argument] = [.library(path: Path.root.join("some/lpath1"), headersPath: Path.root.join("hpath1")), .library(path: Path.root.join("tmp/lpath2"), headersPath: Path.root.join("tmp/hpath2")), .output(path: Path.root.join("tmp/opath.xcframework"))]
        #expect(arguments == expected)
    }

}

@Suite(.requireHostOS(.macOS))
fileprivate struct XCFrameworkCreationCommandTests: CoreBasedTests {
    init() async throws {
        xcode = try await InstalledXcode.currentlySelected()
    }

    let xcode: InstalledXcode

    @Test
    func macFramework_swift() async throws {
        try await _testMacFramework(useSwift: true)
    }

    @Test
    func macFramework_nonswift() async throws {
        try await _testMacFramework(useSwift: false)
    }

    @Test
    func macFrameworkWithDSYMs_swift() async throws {
        try await _testMacFramework(useSwift: true, withDebugSymbols: true)
    }

    @Test
    func macFrameworkWithDSYMs_nonswift() async throws {
        try await _testMacFramework(useSwift: false, withDebugSymbols: true)
    }

    func _testMacFramework(useSwift: Bool, withDebugSymbols: Bool = false) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileFramework(path: tmpDir, platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let debugSymbolPaths = withDebugSymbols ? [tmpDir.join(path.basenameWithoutSuffix + ".framework.dSYM")] : []

            let result = XCFramework.framework(from: path, debugSymbolPaths: debugSymbolPaths, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "macos-x86_64")
            #expect(library.libraryPath == Path("sample.framework"))
            #expect(library.binaryPath == Path("sample.framework/Versions/A/sample"))
            #expect(library.supportedPlatform == "macos")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath == nil)
            if withDebugSymbols {
                #expect(library.debugSymbolsPath?.str == "dSYMs")
            }
            else {
                #expect(library.debugSymbolsPath == nil)
            }
            #expect(library.libraryType == .framework)
        }
    }

    @Test
    func macDynamicLibrary_swift() async throws {
        try await _testMacDynamicLibrary(useSwift: true)
    }

    @Test
    func macDynamicLibrary_nonswift() async throws {
        try await _testMacDynamicLibrary(useSwift: false)
    }

    func _testMacDynamicLibrary(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileDynamicLibrary(path: tmpDir, platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let result = XCFramework.library(from: path, headersPath: nil, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "macos-x86_64")
            #expect(library.libraryPath == Path("libsample.dylib"))
            #expect(library.binaryPath == Path("libsample.dylib"))
            #expect(library.supportedPlatform == "macos")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .dynamicLibrary)
        }
    }

    @Test
    func macFatStaticLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileStaticLibrary(path: tmpDir, platform: .macOS, infoLookup: infoLookup, archs: ["x86_64", "x86_64h"])

            let result = XCFramework.library(from: path, headersPath: Path("Headers"), infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "macos-x86_64_x86_64h")
            #expect(library.libraryPath == Path("libsample.a"))
            #expect(library.binaryPath == Path("libsample.a"))
            #expect(library.supportedPlatform == "macos")
            #expect(library.supportedArchitectures == ["x86_64", "x86_64h"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath?.str == "Headers")
            #expect(library.libraryType == .staticLibrary)
        }
    }

    @Test
    func macStaticLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileStaticLibrary(path: tmpDir, platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"])

            let result = XCFramework.library(from: path, headersPath: Path("Headers"), infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "macos-x86_64")
            #expect(library.libraryPath == Path("libsample.a"))
            #expect(library.binaryPath == Path("libsample.a"))
            #expect(library.supportedPlatform == "macos")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath?.str == "Headers")
            #expect(library.libraryType == .staticLibrary)
        }
    }

    @Test(.requireSDKs(.driverKit))
    func driverKitFramework() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileFramework(path: tmpDir, platform: .driverKit, infoLookup: infoLookup, archs: ["x86_64"], useSwift: false)

            let result = XCFramework.framework(from: path, infoLookup: infoLookup)
            let library = try #require(result.library)

            #expect(library.libraryIdentifier == "driverkit-x86_64")
            #expect(library.libraryPath == Path("sample.framework"))
            #expect(library.binaryPath == Path("sample.framework/sample"))
            #expect(library.supportedPlatform == "driverkit")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .framework)
        }
    }

    @Test(.requireSDKs(.driverKit))
    func driverKitDynamicLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileDynamicLibrary(path: tmpDir, platform: .driverKit, infoLookup: infoLookup, archs: ["x86_64"], useSwift: false)

            let result = XCFramework.library(from: path, headersPath: nil, infoLookup: infoLookup)
            let library = try #require(result.library)

            #expect(library.libraryIdentifier == "driverkit-x86_64")
            #expect(library.libraryPath == Path("libsample.dylib"))
            #expect(library.binaryPath == Path("libsample.dylib"))
            #expect(library.supportedPlatform == "driverkit")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .dynamicLibrary)
        }
    }

    @Test(.requireSDKs(.driverKit))
    func driverKitStaticLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileStaticLibrary(path: tmpDir, platform: .driverKit, infoLookup: infoLookup, archs: ["x86_64"])

            let result = XCFramework.library(from: path, headersPath: Path("Headers"), infoLookup: infoLookup)
            let library = try #require(result.library)

            #expect(library.libraryIdentifier == "driverkit-x86_64")
            #expect(library.libraryPath == Path("libsample.a"))
            #expect(library.binaryPath == Path("libsample.a"))
            #expect(library.supportedPlatform == "driverkit")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath?.str == "Headers")
            #expect(library.libraryType == .staticLibrary)
        }
    }

    @Test
    func iOSFramework_swift() async throws {
        try await _testiOSFramework(useSwift: true)
    }

    @Test
    func iOSFramework_nonswift() async throws {
        try await _testiOSFramework(useSwift: false)
    }

    @Test
    func iOSFrameworkWithDebugSymbols_swift() async throws {
        try await _testiOSFramework(useSwift: true, withDebugSymbols: true)
    }

    @Test
    func iOSFrameworkWithDebugSymbols_nonswift() async throws {
        try await _testiOSFramework(useSwift: false,  withDebugSymbols: true)
    }

    func _testiOSFramework(useSwift: Bool, withDebugSymbols: Bool = true) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileFramework(path: tmpDir, platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)

            let debugSymbolPaths: [Path]
            if withDebugSymbols {
                debugSymbolPaths = [
                    tmpDir.join(path.basenameWithoutSuffix + ".framework.dSYM"),
                ]
            }
            else {
                debugSymbolPaths = []
            }

            let result = XCFramework.framework(from: path, debugSymbolPaths: debugSymbolPaths, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "ios-arm64_arm64e")
            #expect(library.libraryPath == Path("sample.framework"))
            #expect(library.binaryPath == Path("sample.framework/sample"))
            #expect(library.supportedPlatform == "ios")
            #expect(library.supportedArchitectures == ["arm64", "arm64e"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath == nil)
            if withDebugSymbols {
                #expect(library.debugSymbolsPath?.str == "dSYMs")
            }
            else {
                #expect(library.debugSymbolsPath == nil)
            }
            #expect(library.libraryType == .framework)
        }
    }

    @Test
    func iOSDynamicLibrary_swift() async throws {
        try await _testiOSDynamicLibrary(useSwift: true)
    }

    @Test
    func iOSDynamicLibrary_nonswift() async throws {
        try await _testiOSDynamicLibrary(useSwift: false)
    }

    func _testiOSDynamicLibrary(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileDynamicLibrary(path: tmpDir, platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)

            let result = XCFramework.library(from: path, headersPath: nil, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "ios-arm64_arm64e")
            #expect(library.libraryPath == Path("libsample.dylib"))
            #expect(library.binaryPath == Path("libsample.dylib"))
            #expect(library.supportedPlatform == "ios")
            #expect(library.supportedArchitectures == ["arm64", "arm64e"])
            #expect(library.platformVariant == nil)
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .dynamicLibrary)
        }
    }

    @Test
    func iOSSimulatorFramework_swift() async throws {
        try await _testiOSSimulatorFramework(useSwift: true)
    }

    @Test
    func iOSSimulatorFramework_nonswift() async throws {
        try await _testiOSSimulatorFramework(useSwift: false)
    }

    func _testiOSSimulatorFramework(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileFramework(path: tmpDir, platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let result = XCFramework.framework(from: path, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "ios-x86_64-simulator")
            #expect(library.libraryPath == Path("sample.framework"))
            #expect(library.binaryPath == Path("sample.framework/sample"))
            #expect(library.supportedPlatform == "ios")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == "simulator")
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .framework)
        }
    }

    @Test
    func iOSSimulatorDynamicLibrary_swift() async throws {
        try await _testiOSSimulatorDynamicLibrary(useSwift: true)
    }

    @Test
    func iOSSimulatorDynamicLibrary_nonswift() async throws {
        try await _testiOSSimulatorDynamicLibrary(useSwift: false)
    }

    func _testiOSSimulatorDynamicLibrary(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileDynamicLibrary(path: tmpDir, platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let result = XCFramework.library(from: path, headersPath: nil, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "ios-x86_64-simulator")
            #expect(library.libraryPath == Path("libsample.dylib"))
            #expect(library.binaryPath == Path("libsample.dylib"))
            #expect(library.supportedPlatform == "ios")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == "simulator")
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .dynamicLibrary)
        }
    }

    @Test
    func macCatalystDynamicLibrary_swift() async throws {
        try await _testMacCatalystDynamicLibrary(useSwift: true)
    }

    @Test
    func macCatalystDynamicLibrary_nonswift() async throws {
        try await _testMacCatalystDynamicLibrary(useSwift: false)
    }

    func _testMacCatalystDynamicLibrary(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path = try await xcode.compileDynamicLibrary(path: tmpDir, platform: .macCatalyst, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let result = XCFramework.library(from: path, headersPath: nil, infoLookup: infoLookup)
            guard let library = result.library else {
                Issue.record(Comment(rawValue: result.error!.message))
                return
            }

            #expect(library.libraryIdentifier == "ios-x86_64-maccatalyst")
            #expect(library.libraryPath == Path("libsample.dylib"))
            #expect(library.binaryPath == Path("libsample.dylib"))
            #expect(library.supportedPlatform == "ios")
            #expect(library.supportedArchitectures == ["x86_64"])
            #expect(library.platformVariant == "macabi")
            #expect(library.headersPath == nil)
            #expect(library.libraryType == .dynamicLibrary)
        }
    }

    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func XCFrameworkCommandForFrameworks_swift() async throws {
        try await _testXCFrameworkCommandForFrameworks(useSwift: true, allowInternalDistribution: false)
    }

    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func XCFrameworkCommandForFrameworks_swiftWithInternals() async throws {
        try await _testXCFrameworkCommandForFrameworks(useSwift: true, allowInternalDistribution: true)
    }

    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func XCFrameworkCommandForFrameworks_nonswift() async throws {
        try await _testXCFrameworkCommandForFrameworks(useSwift: false, allowInternalDistribution: false)
    }

    func _testXCFrameworkCommandForFrameworks(useSwift: Bool, allowInternalDistribution: Bool) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()

            let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)
            let path2 = try await xcode.compileFramework(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)
            let path3 = try await xcode.compileFramework(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)
            let path4 = try await xcode.compileFramework(path: tmpDir.join("driverkit"), platform: .driverKit, infoLookup: infoLookup, archs: ["x86_64"], useSwift: false)

            let outputPath = tmpDir.join("sample.xcframework")

            // Create a fake dSYM file as we don't actually need a real one for testing this. However, only do this for some of the platforms to ensure that mixing works properly.
            func createFakeDebugFile(at root: Path) throws -> Path {
                let dsymRootPath = root.dirname.join("dSYMs")
                try localFS.createDirectory(dsymRootPath, recursive: true)
                let dsymPath = dsymRootPath.join(root.basename + ".dSYM")
                try localFS.write(dsymPath, contents: ByteString("mock debug symbols file"))

                return dsymPath
            }
            let dsymPath1 = try createFakeDebugFile(at: path1)
            let dsymPath4 = try createFakeDebugFile(at: path4)

            let commandLine = ["createXCFramework", "-framework", path1.str, "-debug-symbols", dsymPath1.str, "-framework", path2.str, "-framework", path3.str, "-framework", path4.str, "-debug-symbols", dsymPath4.str, "-output", outputPath.str] + (allowInternalDistribution ? ["-allow-internal-distribution"] : [])

            // Validate that the output is correct.
            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(passed, "unable to create the xcframework successfully.")
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")

            // Inspect the results xcframework for correctness.
            let xcframework = try XCFramework(path: outputPath, fs: localFS)
            #expect(xcframework.version == Version(1))
            #expect(xcframework.libraries.count == 4)

            guard let macos = xcframework.findLibrary(platform: "macos") else {
                Issue.record("no library found for macos")
                return
            }
            guard let iphoneos = xcframework.findLibrary(platform: "ios") else {
                Issue.record("no library found for ios")
                return
            }
            guard let iphonesimulator = xcframework.findLibrary(platform: "ios", platformVariant: "simulator") else {
                Issue.record("no library found for ios-simulator")
                return
            }
            let driverkit = try #require(xcframework.findLibrary(platform: "driverkit"), "no library found for driverkit")

            #expect(macos.libraryPath.str == "sample.framework")
            #expect(macos.libraryType == .framework)
            #expect(macos.libraryIdentifier == "macos-x86_64")
            #expect(macos.supportedPlatform == "macos")
            #expect(macos.supportedArchitectures == ["x86_64"])
            #expect(macos.headersPath == nil)
            #expect(macos.debugSymbolsPath?.str == "dSYMs")
            #expect(macos.platformVariant == nil)

            #expect(iphoneos.libraryPath.str == "sample.framework")
            #expect(iphoneos.libraryType == .framework)
            #expect(iphoneos.libraryIdentifier == "ios-arm64_arm64e")
            #expect(iphoneos.supportedPlatform == "ios")
            #expect(iphoneos.supportedArchitectures == ["arm64", "arm64e"])
            #expect(iphoneos.headersPath == nil)
            #expect(iphoneos.debugSymbolsPath == nil)
            #expect(iphoneos.platformVariant == nil)

            #expect(iphonesimulator.libraryPath.str == "sample.framework")
            #expect(iphonesimulator.libraryType == .framework)
            #expect(iphonesimulator.libraryIdentifier == "ios-x86_64-simulator")
            #expect(iphonesimulator.supportedPlatform == "ios")
            #expect(iphonesimulator.supportedArchitectures == ["x86_64"])
            #expect(iphonesimulator.platformVariant == "simulator")
            #expect(iphonesimulator.headersPath == nil)
            #expect(iphonesimulator.debugSymbolsPath == nil)

            #expect(driverkit.libraryPath.str == "sample.framework")
            #expect(driverkit.libraryType == .framework)
            #expect(driverkit.libraryIdentifier == "driverkit-x86_64")
            #expect(driverkit.supportedPlatform == "driverkit")
            #expect(driverkit.supportedArchitectures == ["x86_64"])
            #expect(driverkit.headersPath == nil)
            #expect(macos.debugSymbolsPath?.str == "dSYMs")
            #expect(driverkit.platformVariant == nil)

            // Validate that there are actually files on disk in the correct location.
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join(macos.libraryPath)))
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join(macos.libraryPath).join("Modules").join("\(macos.libraryPath.basenameWithoutSuffix).swiftmodule").join("\(macos.libraryPath.basenameWithoutSuffix).swiftinterface")) == useSwift)
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join(macos.libraryPath)))
            if let debugSymbolsPath = macos.debugSymbolsPath {
                #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join(debugSymbolsPath).join(macos.libraryPath.str + ".dSYM")))
            }
            else {
                Issue.record("Missing the debug symbols path")
            }

            #expect(localFS.exists(outputPath.join(iphoneos.libraryIdentifier).join(iphoneos.libraryPath).join("Modules").join("\(iphoneos.libraryPath.basenameWithoutSuffix).swiftmodule").join("\(iphoneos.libraryPath.basenameWithoutSuffix).swiftinterface")) == useSwift)

            #expect(localFS.exists(outputPath.join(iphonesimulator.libraryIdentifier).join(iphonesimulator.libraryPath)))
            #expect(localFS.exists(outputPath.join(iphonesimulator.libraryIdentifier).join(iphonesimulator.libraryPath).join("Modules").join("\(iphonesimulator.libraryPath.basenameWithoutSuffix).swiftmodule").join("\(iphonesimulator.libraryPath.basenameWithoutSuffix).swiftinterface")) == useSwift)

            #expect(localFS.exists(outputPath.join(driverkit.libraryIdentifier).join(driverkit.libraryPath)))
            if let debugSymbolsPath = driverkit.debugSymbolsPath {
                #expect(localFS.exists(outputPath.join(driverkit.libraryIdentifier).join(debugSymbolsPath).join(driverkit.libraryPath.str + ".dSYM")))
            }
            else {
                Issue.record("Missing the debug symbols path")
            }

            var swiftModuleFilesFound: [Path] = []
            try localFS.traverse(outputPath) {
                if $0.fileSuffix == ".swiftmodule" && !localFS.isDirectory($0) {
                    swiftModuleFilesFound.append($0)
                }
            }

            if allowInternalDistribution {
                #expect(!swiftModuleFilesFound.isEmpty, "The swiftmodule files should not have been removed.")
            }
            else {
                #expect(swiftModuleFilesFound.isEmpty, "The swiftmodule files should have been removed: \(swiftModuleFilesFound)")
            }
        }
    }

    @Test
    func XCFrameworkCommandForDynamicLibraries_swift() async throws {
        try await _testXCFrameworkCommandForDynamicLibraries(useSwift: true)
    }

    @Test
    func XCFrameworkCommandForDynamicLibraries_swift_internalDistribution() async throws {
        try await _testXCFrameworkCommandForDynamicLibraries(useSwift: true, allowInternalDistribution: true)
    }

    @Test
    func XCFrameworkCommandForDynamicLibraries_nonswift() async throws {
        try await _testXCFrameworkCommandForDynamicLibraries(useSwift: false)
    }

    func _testXCFrameworkCommandForDynamicLibraries(useSwift: Bool, allowInternalDistribution: Bool = false) async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()

            let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)
            let path2 = try await xcode.compileDynamicLibrary(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)
            let path3 = try await xcode.compileDynamicLibrary(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let outputPath = tmpDir.join("sample.xcframework")


            // Create a fake dSYM file as we don't actually need a real one for testing this. However, only do this for some of the platforms to ensure that mixing works properly.
            func createFakeDebugFile(at root: Path, bundle: Bool = false, basename: String? = nil, fileExtension: String = "dSYM") throws -> Path {
                let dsymRootPath = root.dirname.join("dSYMs")
                try localFS.createDirectory(dsymRootPath, recursive: true)

                let basename = basename ?? root.basename
                let dsymPath = dsymRootPath.join(basename + ".\(fileExtension)")

                // Treat the .dSYM root as a bundle, not just a file.
                if bundle {
                    try localFS.createDirectory(dsymPath, recursive: true)
                    try localFS.write(dsymPath.join("part1.\(fileExtension)"), contents: ByteString("mock debug symbols file"))
                    try localFS.write(dsymPath.join("part2.\(fileExtension)"), contents: ByteString("another mock debug symbols file"))
                }
                else {
                    try localFS.write(dsymPath, contents: ByteString("mock debug symbols file"))
                }

                return dsymPath
            }
            let dsymPath1 = try createFakeDebugFile(at: path1, bundle: true)
            let dsymPath3 = try createFakeDebugFile(at: path3)

            let commandLine: [String]
            commandLine = ["createXCFramework", "-library", path1.str, "-debug-symbols", dsymPath1.str, "-headers", path1.dirname.join("include").str, "-library", path2.str, "-headers", path2.dirname.join("include").str, "-library", path3.str, "-headers", path3.dirname.join("include").str, "-debug-symbols", dsymPath3.str, "-output", outputPath.str] + (allowInternalDistribution ? ["-allow-internal-distribution"] : [])

            // Validate that the output is correct.
            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(passed, "unable to create the xcframework successfully.")
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")

            // Inspect the results xcframework for correctness.
            let xcframework = try XCFramework(path: outputPath, fs: localFS)
            #expect(xcframework.version == Version(1))
            #expect(xcframework.libraries.count == 3)

            guard let macos = xcframework.findLibrary(platform: "macos") else {
                Issue.record("no library found for macos")
                return
            }
            guard let iphoneos = xcframework.findLibrary(platform: "ios") else {
                Issue.record("no library found for ios")
                return
            }
            guard let iphonesimulator = xcframework.findLibrary(platform: "ios", platformVariant: "simulator") else {
                Issue.record("no library found for ios-simulator")
                return
            }

            let expectedHeadersPath = "Headers"

            #expect(macos.libraryPath.str == "libsample.dylib")
            #expect(macos.libraryType == .dynamicLibrary)
            #expect(macos.libraryIdentifier == "macos-x86_64")
            #expect(macos.supportedPlatform == "macos")
            #expect(macos.supportedArchitectures == ["x86_64"])
            #expect(macos.headersPath?.str == expectedHeadersPath)
            #expect(macos.debugSymbolsPath?.str == "dSYMs")
            #expect(macos.platformVariant == nil)

            #expect(iphoneos.libraryPath.str == "libsample.dylib")
            #expect(iphoneos.libraryType == .dynamicLibrary)
            #expect(iphoneos.libraryIdentifier == "ios-arm64_arm64e")
            #expect(iphoneos.supportedPlatform == "ios")
            #expect(iphoneos.supportedArchitectures == ["arm64", "arm64e"])
            #expect(iphoneos.headersPath?.str == expectedHeadersPath)
            #expect(iphoneos.debugSymbolsPath == nil)
            #expect(iphoneos.platformVariant == nil)

            #expect(iphonesimulator.libraryPath.str == "libsample.dylib")
            #expect(iphonesimulator.libraryType == .dynamicLibrary)
            #expect(iphonesimulator.libraryIdentifier == "ios-x86_64-simulator")
            #expect(iphonesimulator.supportedPlatform == "ios")
            #expect(iphonesimulator.supportedArchitectures == ["x86_64"])
            #expect(iphonesimulator.platformVariant == "simulator")
            #expect(iphonesimulator.headersPath?.str == expectedHeadersPath)
            #expect(iphonesimulator.debugSymbolsPath?.str == "dSYMs")

            // Validate that there are actually files on disk in the correct location.
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join(macos.libraryPath)))
            #expect(localFS.exists(outputPath.join(iphoneos.libraryIdentifier).join(iphoneos.libraryPath)))
            #expect(localFS.exists(outputPath.join(iphonesimulator.libraryIdentifier).join(iphonesimulator.libraryPath)))

            // Validate the dSYMs are in place.
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join("dSYMs").join(macos.libraryPath.str + ".dSYM")))
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join("dSYMs").join(macos.libraryPath.str + ".dSYM").join("part1.dSYM")))
            #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join("dSYMs").join(macos.libraryPath.str + ".dSYM").join("part2.dSYM")))
            #expect(localFS.exists(outputPath.join(iphonesimulator.libraryIdentifier).join("dSYMs").join(iphonesimulator.libraryPath.str + ".dSYM")))
            #expect(!localFS.exists(outputPath.join(iphoneos.libraryIdentifier).join("dSYMs").join(iphoneos.libraryPath.str + ".dSYM")))

            // Validate the bcsymbolmaps are in place.
            #expect(!localFS.exists(outputPath.join(macos.libraryIdentifier).join("BCSymbolMaps")))
            #expect(!localFS.exists(outputPath.join(iphoneos.libraryIdentifier).join("BCSymbolMaps")))

            if useSwift {
                let macosSwiftModuleDir = outputPath.join(macos.libraryIdentifier).join(macos.headersPath!).join("sample.swiftmodule")
                #expect(localFS.exists(macosSwiftModuleDir.join("x86_64.swiftmodule")) == allowInternalDistribution)
                #expect(localFS.exists(macosSwiftModuleDir.join("sample.swiftinterface")))
                #expect(localFS.exists(macosSwiftModuleDir.join("x86_64.swiftdoc")))

                let iphoneosSwiftModuleDir = outputPath.join(iphoneos.libraryIdentifier).join(iphoneos.headersPath!).join("sample.swiftmodule")
                #expect(localFS.exists(iphoneosSwiftModuleDir.join("arm64.swiftmodule")) == allowInternalDistribution)
                #expect(localFS.exists(iphoneosSwiftModuleDir.join("arm64e.swiftmodule")) == allowInternalDistribution)
                #expect(localFS.exists(iphoneosSwiftModuleDir.join("sample.swiftinterface")))
                #expect(localFS.exists(iphoneosSwiftModuleDir.join("arm64.swiftdoc")))
                #expect(localFS.exists(iphoneosSwiftModuleDir.join("arm64e.swiftdoc")))

                let iphonesimulatorSwiftModuleDir = outputPath.join(iphonesimulator.libraryIdentifier).join(iphonesimulator.headersPath!).join("sample.swiftmodule")
                #expect(localFS.exists(iphonesimulatorSwiftModuleDir.join("x86_64.swiftmodule")) == allowInternalDistribution)
                #expect(localFS.exists(iphonesimulatorSwiftModuleDir.join("sample.swiftinterface")))
                #expect(localFS.exists(iphonesimulatorSwiftModuleDir.join("x86_64.swiftdoc")))
            }
            else {
                #expect(localFS.exists(outputPath.join(macos.libraryIdentifier).join(macos.headersPath!).join("source.h")))
                #expect(localFS.exists(outputPath.join(iphoneos.libraryIdentifier).join(iphoneos.headersPath!).join("source.h")))
                #expect(localFS.exists(outputPath.join(iphonesimulator.libraryIdentifier).join(iphonesimulator.headersPath!).join("source.h")))
            }
        }
    }

    @Test
    func XCFrameworkCommandForArchive() throws {
        let fs = PseudoFS()
        let cwd = Path("/var/tmp")

        // Test that rewriting is happening properly.
        func testCommandLineRewrite(_ args: [String], expected: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
            let commandLine = XCFramework.rewriteCommandLine(args, cwd: cwd, fs: fs)
            #expect(commandLine == expected, sourceLocation: sourceLocation)
        }

        // Create the general layout and stubs for an archive as the re-write logic checks for existence.
        try fs.createDirectory(Path("/var/tmp/hi.xcarchive/Products/Library/Frameworks/hi.framework"), recursive: true)
        try fs.createDirectory(Path("/var/tmp/hi.xcarchive/Products/usr/local/include"), recursive: true)
        try fs.createDirectory(Path("/var/tmp/hi.xcarchive/Products/usr/local/lib"), recursive: true)
        try fs.write(Path("/var/tmp/hi.xcarchive/Products/usr/local/lib/libhi.a"), contents: "staticlib!")
        try fs.write(Path("/var/tmp/hi.xcarchive/Products/usr/local/lib/hi.dylib"), contents: "staticlib!")
        try fs.write(Path("/var/tmp/hi.xcarchive/Products/usr/local/include/hi.h"), contents: "// header!")

        try fs.createDirectory(Path("/var/tmp/hi.xcarchive/dSYMs/hi.framework.dSYM"), recursive: true)
        try fs.createDirectory(Path("/var/tmp/hi.xcarchive/dSYMs/libhi.a.dSYM"), recursive: true)
        // explicitly missing dSYM for 'hi.dylib'
        try fs.createDirectory(Path("/var/tmp/hi.xcarchive/BCSymbolMaps"), recursive: true)

        try fs.createDirectory(Path("/var/tmp/bye.xcarchive/Products/Library/Frameworks/bye.framework"), recursive: true)
        try fs.createDirectory(Path("/var/tmp/bye.xcarchive/Products/usr/local/lib"), recursive: true)
        try fs.write(Path("/var/tmp/bye.xcarchive/Products/usr/local/lib/libbye.a"), contents: "staticlib!")
        // explicitly missing headers
        try fs.createDirectory(Path("/var/tmp/bye.xcarchive/dSYMs/bye.framework.dSYM"), recursive: true)
        // explicitly missing dSYM
        try fs.createDirectory(Path("/var/tmp/bye.xcarchive/BCSymbolMaps"), recursive: true)

        try testCommandLineRewrite([
            "-create-xcframework",
            "-framework", "hi.framework",
            "-framework", "bye.framework",
            "-output", "/var/tmp/my.xcframework",
        ],
                                   expected: [
                                    "-create-xcframework",
                                    "-framework", "hi.framework",
                                    "-framework", "bye.framework",
                                    "-output", "/var/tmp/my.xcframework",
                                   ])

        try testCommandLineRewrite([
            "-create-xcframework",
            "-archive", "/var/tmp/hi.xcarchive", "-framework", "hi.framework",
            "-archive", "/var/tmp/bye.xcarchive", "-framework", "bye.framework",
            "-output", "/var/tmp/my.xcframework",
        ],
                                   expected: [
                                    "-create-xcframework",
                                    "-framework", "/var/tmp/hi.xcarchive/Products/Library/Frameworks/hi.framework", "-debug-symbols", "/var/tmp/hi.xcarchive/dSYMs/hi.framework.dSYM",
                                    "-framework", "/var/tmp/bye.xcarchive/Products/Library/Frameworks/bye.framework", "-debug-symbols", "/var/tmp/bye.xcarchive/dSYMs/bye.framework.dSYM",
                                    "-output", "/var/tmp/my.xcframework",
                                   ])

        try testCommandLineRewrite([
            "-create-xcframework",
            "-archive", "/var/tmp/hi.xcarchive", "-library", "libhi.a",
            "-archive", "/var/tmp/hi.xcarchive", "-library", "hi.dylib",
            "-archive", "/var/tmp/bye.xcarchive", "-library", "libbye.a",
            "-output", "/var/tmp/my.xcframework",
        ],
                                   expected: [
                                    "-create-xcframework",
                                    "-library", "/var/tmp/hi.xcarchive/Products/usr/local/lib/libhi.a", "-headers", "/var/tmp/hi.xcarchive/Products/usr/local/include", "-debug-symbols", "/var/tmp/hi.xcarchive/dSYMs/libhi.a.dSYM",
                                    "-library", "/var/tmp/hi.xcarchive/Products/usr/local/lib/hi.dylib", "-headers", "/var/tmp/hi.xcarchive/Products/usr/local/include",
                                    "-library", "/var/tmp/bye.xcarchive/Products/usr/local/lib/libbye.a",
                                    "-output", "/var/tmp/my.xcframework",
                                   ])

        try testCommandLineRewrite([
            "-create-xcframework",
            "-archive", "/var/tmp/hi.xcarchive", "-library", "libhi.a",
            /* skip -archive and inherit it */ "-library", "hi.dylib",
            "-archive", "/var/tmp/bye.xcarchive", "-library", "libbye.a",
            "-output", "/var/tmp/my.xcframework",
        ],
                                   expected: [
                                    "-create-xcframework",
                                    "-library", "/var/tmp/hi.xcarchive/Products/usr/local/lib/libhi.a", "-headers", "/var/tmp/hi.xcarchive/Products/usr/local/include", "-debug-symbols", "/var/tmp/hi.xcarchive/dSYMs/libhi.a.dSYM",
                                    "-library", "/var/tmp/hi.xcarchive/Products/usr/local/lib/hi.dylib", "-headers", "/var/tmp/hi.xcarchive/Products/usr/local/include",
                                    "-library", "/var/tmp/bye.xcarchive/Products/usr/local/lib/libbye.a",
                                    "-output", "/var/tmp/my.xcframework",
                                   ])

        // This will create an invalid command-line, but the only test consideration here is that the rewriting happens appropriately.
        let expectedCommandLine = [
            "-create-xcframework",
            "-framework", "/var/tmp/hi.xcarchive/Products/Library/Frameworks/hi.framework", "-debug-symbols", "/var/tmp/hi.xcarchive/dSYMs/hi.framework.dSYM",
            "-library", "/var/tmp/hi.xcarchive/Products/usr/local/lib/-allow-internal-distribution", "-headers", "/var/tmp/hi.xcarchive/Products/usr/local/include",
            "-output", "/var/tmp/my.xcframework",
        ]
        try testCommandLineRewrite([
            "-create-xcframework",
            "-archive", "/var/tmp/hi.xcarchive", "-framework", "hi.framework", "-library", "-allow-internal-distribution",
            "-output", "/var/tmp/my.xcframework",
        ],
                                   expected: expectedCommandLine)

        let result = XCFramework.parseCommandLine(args: expectedCommandLine, currentWorkingDirectory: cwd, fs: fs)
        #expect(result.error?.message == "error: an xcframework cannot contain both frameworks and libraries.")
    }

    @Test
    func buildLibraryForDistributionError_DynamicLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, buildLibraryForDistribution: false)
            let outputPath = tmpDir.join("sample.xcframework")
            let commandLine: [String] = ["createXCFramework", "-library", path1.str, "-headers", path1.dirname.join("include").str, "-output", outputPath.str]

            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(!passed, "The xcframework should not have been created successfully.")
            #expect(output.hasPrefix("No \'swiftinterface\' files found within \'\(path1.dirname.str)/include/sample.swiftmodule\'.\n"), "unexpected output: \(output)")
        }
    }

    @Test
    func buildLibraryForDistributionNoHeaders_DynamicLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, buildLibraryForDistribution: false)
            let outputPath = tmpDir.join("sample.xcframework")
            let commandLine: [String] = ["createXCFramework", "-library", path1.str, "-output", outputPath.str]

            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(passed, "unable to create the xcframework successfully.")
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")
        }
    }

    @Test
    func buildLibraryForDistributionOverride_DynamicLibrary() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, buildLibraryForDistribution: false)
            let outputPath = tmpDir.join("sample.xcframework")
            let commandLine: [String] = ["createXCFramework", "-allow-internal-distribution", "-library", path1.str, "-headers", path1.dirname.join("include").str, "-output", outputPath.str]

            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(passed, "unable to create the xcframework successfully.")
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")
        }
    }

    @Test
    func buildLibraryForDistributionError_Framework() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, buildLibraryForDistribution: false)
            let outputPath = tmpDir.join("sample.xcframework")
            let commandLine: [String] = ["createXCFramework", "-framework", path1.str, "-output", outputPath.str]

            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(!passed, "The xcframework should not have been created successfully.")
            #expect(output.hasPrefix("No \'swiftinterface\' files found within \'\(path1.str)/Modules/sample.swiftmodule\'.\n"), "unexpected output: \(output)")
        }
    }

    @Test
    func buildLibraryForDistributionOverride_Framework() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, buildLibraryForDistribution: false)
            let outputPath = tmpDir.join("sample.xcframework")
            let commandLine: [String] = ["createXCFramework", "-framework", path1.str, "-output", outputPath.str, "-allow-internal-distribution"]

            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(passed, "unable to create the xcframework successfully.")
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")
        }
    }

    @Test
    func validateLibraryForDistributionForFlatSwiftModuleStructure() async throws {
        let fs = localFS

        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, buildLibraryForDistribution: false)
            let outputPath = tmpDir.join("sample.xcframework")

            let specialIncludePath = path1.dirname.join("special_include")
            try fs.createDirectory(specialIncludePath, recursive: true)
            try fs.write(specialIncludePath.join("sample.swiftmodule"), contents: "just a file")

            let commandLine: [String] = ["createXCFramework", "-library", path1.str, "-headers", specialIncludePath.str, "-output", outputPath.str]
            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            #expect(passed, "unable to create the xcframework successfully.")
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")
        }
    }


    // MARK: Creating XCFrameworks with mergeable libraries


    /// Creates several frameworks, some of which contain mergeable libraries, and creates an XCFramework from them.  Then checks that the correct metadata for each library was added to the Info.plist.
    @Test
    func createXCFrameworkWithMergeableLibraries() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            let infoLookup = try await getCore()

            // The macOS and iOS frameworks have mergeable metadata, but the iOS simulator one does not.
            let macosPath = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["arm64", "x86_64"], useSwift: true, linkerOptions: [.makeMergeable])
            let iosPath = try await xcode.compileFramework(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64"], useSwift: true, linkerOptions: [.makeMergeable])
            let iosSimPath = try await xcode.compileFramework(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["arm64", "x86_64"], useSwift: true)

            let outputPath = tmpDir.join("sample.xcframework")

            let commandLine = ["createXCFramework", "-framework", macosPath.str, "-framework", iosPath.str, "-framework", iosSimPath.str, "-output", outputPath.str]

            // Validate that the output is correct.
            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDir, infoLookup: infoLookup)
            if !passed {
                Issue.record("unable to create the xcframework successfully.")
                return
            }
            #expect(output.hasPrefix("xcframework successfully written out to: \(outputPath.str)"), "unexpected output: \(output)")

            // Inspect the results xcframework for correctness.
            let xcframework = try XCFramework(path: outputPath, fs: localFS)
            #expect(xcframework.version >= XCFramework.mergeableMetadataVersion, "expected xcframework version to be at least \(XCFramework.mergeableMetadataVersion) but it is \(xcframework.version)")
            #expect(xcframework.libraries.count == 3)

            guard let macos = xcframework.findLibrary(platform: "macos") else {
                Issue.record("no library found for macos")
                return
            }
            guard let iphoneos = xcframework.findLibrary(platform: "ios") else {
                Issue.record("no library found for ios")
                return
            }
            guard let iphonesimulator = xcframework.findLibrary(platform: "ios", platformVariant: "simulator") else {
                Issue.record("no library found for ios-simulator")
                return
            }

            // For each platform, validate the library and that it is marked as containing mergeable metadata if appropriate.
            #expect(macos.libraryType == .framework)
            #expect(macos.libraryPath.str == "sample.framework")
            #expect(macos.binaryPath?.str == "sample.framework/Versions/A/sample")
            #expect(macos.libraryIdentifier == "macos-arm64_x86_64")
            #expect(macos.supportedPlatform == "macos")
            #expect(macos.supportedArchitectures == ["arm64", "x86_64"])
            #expect(macos.platformVariant == nil)
            #expect(macos.mergeableMetadata)

            #expect(iphoneos.libraryType == .framework)
            #expect(iphoneos.libraryPath.str == "sample.framework")
            #expect(iphoneos.binaryPath?.str == "sample.framework/sample")
            #expect(iphoneos.libraryIdentifier == "ios-arm64")
            #expect(iphoneos.supportedPlatform == "ios")
            #expect(iphoneos.supportedArchitectures == ["arm64"])
            #expect(iphoneos.platformVariant == nil)
            #expect(iphoneos.mergeableMetadata)

            #expect(iphonesimulator.libraryType == .framework)
            #expect(iphonesimulator.libraryPath.str == "sample.framework")
            #expect(iphonesimulator.binaryPath?.str == "sample.framework/sample")
            #expect(iphonesimulator.libraryIdentifier == "ios-arm64_x86_64-simulator")
            #expect(iphonesimulator.supportedPlatform == "ios")
            #expect(iphonesimulator.supportedArchitectures == ["arm64", "x86_64"])
            #expect(iphonesimulator.platformVariant == "simulator")
            // We didn't build the simulator piece as mergeable.
            #expect(!iphonesimulator.mergeableMetadata)
        }
    }


    // MARK: Testing friendly error messages


    @Test
    func friendlyErrorMessageForFrameworkNotExisting() async throws {
        let infoLookup = try await getCore()
        let frameworkPath = Path("/var/tmp/does/not/exist.framework")
        let outputPath = Path("/var/tmp/out.xcframework")

        let commandLine: [String] = ["createXCFramework", "-framework", frameworkPath.str, "-output", outputPath.str]
        let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: Path("/var/tmp"), infoLookup: infoLookup)
        #expect(!passed, "xcframework should not be created successfully.")
        #expect(output.hasPrefix("error: the path does not point to a valid framework: \(frameworkPath.str)"))
    }

    @Test
    func friendlyErrorMessageForLibraryNotExisting() async throws {
        let infoLookup = try await getCore()
        let libraryPath = Path("/var/tmp/does/not/exist.dylib")
        let outputPath = Path("/var/tmp/out.xcframework")

        let commandLine: [String] = ["createXCFramework", "-library", libraryPath.str, "-output", outputPath.str]
        let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: Path("/var/tmp"), infoLookup: infoLookup)
        #expect(!passed, "xcframework should not be created successfully.")
        #expect(output.hasPrefix("error: the path does not point to a valid library: \(libraryPath.str)"))
    }

    @Test
    func friendlyErrorMessageForLibraryHeadersNotExisting() async throws {
        let fs = localFS

        try await withTemporaryDirectory { tmpDir in
            let infoLookup = try await getCore()
            let libraryPath = tmpDir.join("lib.a")
            try fs.write(libraryPath, contents: ByteString(arrayLiteral: 0xFF, 0xFF))

            let headersPath = Path("/var/tmp/does/not/exist/headers")
            let outputPath = Path("/var/tmp/out.xcframework")

            let commandLine: [String] = ["createXCFramework", "-library", libraryPath.str, "-headers", headersPath.str, "-output", outputPath.str]
            let (passed, output) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: Path("/var/tmp"), infoLookup: infoLookup)
            #expect(!passed, "xcframework should not be created successfully.")
            #expect(output.hasPrefix("error: the path does not point to a valid headers location: \(headersPath.str)"))
        }
    }
}

