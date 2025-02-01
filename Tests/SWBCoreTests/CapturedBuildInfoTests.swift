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
import SWBCore
import SWBUtil

@Suite fileprivate struct CapturedBuildInfoTests {
    /// Test round-tripping deserializing and serializing captured build info.
    @Test
    func serializationRoundTripping() throws {
        let origPlist: PropertyListItem = .plDict([
            "version": .plInt(CapturedBuildInfo.currentFormatVersion),
            "targets": .plArray([
                // Trivial instance of a target with no settings.
                .plDict([
                    "name": .plString("All"),
                    "project-path": .plString(Path.root.join("tmp/Stuff/Stuff.xcodeproj").str),
                    "settings": .plArray([
                        .plDict([
                            "name": .plString("project-xcconfig"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("project"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target-xcconfig"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target"),
                            "settings": .plDict([:]),
                        ]),
                    ])
                ]),
                // More interesting instance of a target with a variety of settings.
                .plDict([
                    "name": .plString("App"),
                    "project-path": .plString(Path.root.join("tmp/Stuff/Stuff.xcodeproj").str),
                    "settings": .plArray([
                        .plDict([
                            "name": .plString("project-xcconfig"),
                            "path": .plString(Path.root.join("tmp/Stuff/project.xcconfig").str),
                            "settings": .plDict([
                                "SYMROOT": .plArray([
                                    .plDict([
                                        "value": .plString("/tmp/symroot"),
                                    ]),
                                ]),
                                // OBJROOT has multiple assignments, one of them conditional and using $(inherited).
                                "OBJROOT": .plArray([
                                    .plDict([
                                        "conditions": .plArray([
                                            .plDict([
                                                "name": .plString("sdk"),
                                                "value": .plString("iphoneos*"),
                                            ]),
                                        ]),
                                        "value": .plString("$(inherited)/ios"),
                                    ]),
                                    .plDict([
                                        "value": .plString("/tmp/objroot"),
                                    ]),
                                ]),
                            ]),
                        ]),
                        .plDict([
                            "name": .plString("project"),
                            "settings": .plDict([
                                "SDKROOT": .plArray([
                                    .plDict([
                                        "value": .plString("macosx"),
                                    ]),
                                ]),
                            ]),
                        ]),
                        .plDict([
                            "name": .plString("target-xcconfig"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target"),
                            "settings": .plDict([
                                "PRODUCT_NAME": .plArray([
                                    .plDict([
                                        "value": .plString("$(TARGET_NAME)"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ])
                ]),
            ]),
        ])

        // Deserialize from the property list to the captured info objects.
        let buildInfo: CapturedBuildInfo
        do {
            buildInfo = try CapturedBuildInfo.fromPropertyList(origPlist)
        }
        catch let error as CapturedInfoDeserializationError {
            Issue.record("deserialization failure: \(error.singleLineDescription)")
            return
        }
        catch {
            Issue.record("unrecognized deserialization failure: \(error)")
            return
        }

        // Reserialize to a property list and compare to the original.
        let newPlist = buildInfo.propertyListItem
        #expect(origPlist.deterministicDescription == newPlist.deterministicDescription)
    }


    /// Test errors in deserializing captured build info.
    ///
    /// This test is not intended to be exhaustive, but we can add more checks here as we find more cases that are worth testing.
    @Test
    func deserializationErrors() throws {
        func deserializeAndCheck(plist: PropertyListItem, check: ([String]) -> Void) {
            // Deserialize from the property list to the captured info objects.
            var errors = [String]()
            do {
                let _ = try CapturedBuildInfo.fromPropertyList(plist)
            }
            catch let error as CapturedInfoDeserializationError {
                if case .error(let e) = error {
                    errors = e
                }
            }
            catch {
                errors = ["\(error)"]
            }
            check(errors)
        }

        // Wrong version.
        deserializeAndCheck(plist: .plDict([
            "version": .plInt(0),
            "targets": .plArray([]),
        ])) { errors in
            #expect(errors == ["build info is version 0 but only version \(CapturedBuildInfo.currentFormatVersion) is supported"])
        }

        // Target with no name.
        deserializeAndCheck(plist: .plDict([
            "version": .plInt(CapturedBuildInfo.currentFormatVersion),
            "targets": .plArray([
                .plDict([:]),
            ]),
        ])) { errors in
            #expect(errors == ["target does not have a valid \'name\' entry: {}"])
        }

        // Target with the wrong number of settings tables.
        deserializeAndCheck(plist: .plDict([
            "version": .plInt(CapturedBuildInfo.currentFormatVersion),
            "targets": .plArray([
                .plDict([
                    "name": .plString("App"),
                    "project-path": .plString("/tmp/Stuff/Stuff.xcodeproj"),
                    "settings": .plArray([])
                ]),
            ]),
        ])) { errors in
            #expect(errors == ["target \'App\' does not have the expected 4 build settings tables but has: []"])
        }

        // Target with a bogus settings table.
        deserializeAndCheck(plist: .plDict([
            "version": .plInt(CapturedBuildInfo.currentFormatVersion),
            "targets": .plArray([
                .plDict([
                    "name": .plString("App"),
                    "project-path": .plString("/tmp/Stuff/Stuff.xcodeproj"),
                    "settings": .plArray([
                        .plDict([
                            "name": .plString("project-xcconfig"),
                            "path": .plString("/tmp/Stuff/project.xcconfig"),
                            "settings": .plString("bogus"),
                        ]),
                        .plDict([
                            "name": .plString("project"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target-xcconfig"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target"),
                            "settings": .plDict([:]),
                        ]),
                    ])
                ]),
            ]),
        ])) { errors in
            #expect(errors == [
                "project-xcconfig settings table is missing its settings dictionary: {\"name\":\"project-xcconfig\",\"path\":\"/tmp/Stuff/project.xcconfig\",\"settings\":\"bogus\"}",
                "in target \'App\'",
            ])
        }

        // Target with an assignment whose value is not an array.
        deserializeAndCheck(plist: .plDict([
            "version": .plInt(CapturedBuildInfo.currentFormatVersion),
            "targets": .plArray([
                .plDict([
                    "name": .plString("App"),
                    "project-path": .plString("/tmp/Stuff/Stuff.xcodeproj"),
                    "settings": .plArray([
                        .plDict([
                            "name": .plString("project-xcconfig"),
                            "path": .plString("/tmp/Stuff/project.xcconfig"),
                            "settings": .plDict([
                                "SYMROOT": .plString("/tmp/symroot"),
                            ]),
                        ]),
                        .plDict([
                            "name": .plString("project"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target-xcconfig"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target"),
                            "settings": .plDict([:]),
                        ]),
                    ])
                ]),
            ]),
        ])) { errors in
            #expect(errors == [
                "value for build setting \'SYMROOT\' in project-xcconfig settings table is not an array: \"/tmp/symroot\"",
                "in target \'App\'",
            ])
        }

        // Target with an assignment with a value which is missing.
        deserializeAndCheck(plist: .plDict([
            "version": .plInt(CapturedBuildInfo.currentFormatVersion),
            "targets": .plArray([
                .plDict([
                    "name": .plString("App"),
                    "project-path": .plString("/tmp/Stuff/Stuff.xcodeproj"),
                    "settings": .plArray([
                        .plDict([
                            "name": .plString("project-xcconfig"),
                            "path": .plString("/tmp/Stuff/project.xcconfig"),
                            "settings": .plDict([
                                "SYMROOT": .plArray([
                                    .plDict([:]),
                                ]),
                            ]),
                        ]),
                        .plDict([
                            "name": .plString("project"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target-xcconfig"),
                            "settings": .plDict([:]),
                        ]),
                        .plDict([
                            "name": .plString("target"),
                            "settings": .plDict([:]),
                        ]),
                    ])
                ]),
            ]),
        ])) { errors in
            #expect(errors == [
                "build setting assignment does not have a valid \'value\' entry: {}",
                "for build setting \'SYMROOT\'",
                "in project-xcconfig settings table",
                "in target \'App\'",
            ])
        }
    }

}
