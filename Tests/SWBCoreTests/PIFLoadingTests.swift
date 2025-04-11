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

@_spi(Testing) import SWBCore
import SWBMacro
import SWBProtocol

// MARK: - Test cases for ProjectModelItem class static methods

private final class ProjectModelItemClass: ProjectModelItem {
    let guid: String

    required init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        guid = "nothing"
    }
}

@Suite fileprivate struct ProjectModelItemUnitTests {
    private let testData: [String: PropertyListItem] = [
        "stringKey": "aValue",

        "trueKey": "true",
        "falseKey": "false",

        "arrayOfItemsKey": [
            [
                "guid": "xib-fileReference-guid",
                "type": "file",
                "sourceTree": "<group>",
                "path": "Thingy.xib",
                "fileType": "file.xib",
            ],
            [
                "guid": "fr-strings-fileReference-guid",
                "type": "file",
                "sourceTree": "<group>",
                "path": "Thingy.strings",
                "fileType": "text.plist.strings",
                "regionVariantName": "fr",
            ],
            [
                "guid": "some-fileGroup-guid",
                "name": "Files",
                "type": "group",
                "sourceTree": "<group>",
                "path": "Files",
            ],
        ],

        "arrayOfEmptyDictsKey": [
            [:] as PropertyListItem,
            [:] as PropertyListItem,
            [:] as PropertyListItem,
        ],

        "arrayOfStringsKey": [
            "one", "two", "three", "four", "five",
        ],

        "dictionaryKey": [
            "keyOne": "hmm",
            "keyTwo": "err",
            "keyThree": "aha",
        ],

        "fileGroupKey": [
            "guid": "some-fileGroup-guid",
            "name": "Files",
            "type": "group",
            "sourceTree": "<group>",
            "path": "Files",
        ],

    ]
    private func getTestPlist() throws -> PropertyListItem { .init(testData) }

    /// A mock PIF loader.
    private let pifLoader: PIFLoader

    init() {
        // Create a new PIFLoader for each test case, and discard it at the end.
        pifLoader = PIFLoader(data: .plArray([]), namespace: BuiltinMacros.namespace)
    }

    @Test
    func parseValueForKeyAsString() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the required version.
        let requiredValue = try ProjectModelItemClass.parseValueForKeyAsString("stringKey", pifDict: pifDict)
        #expect(requiredValue == "aValue")

        // Test the optional version.
        let presentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsString("stringKey", pifDict: pifDict)
        #expect(presentValue == "aValue")

        let absentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsString("missingKey", pifDict: pifDict)
        #expect(absentValue == nil)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsString("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "String", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsString("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "String", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsString("missingKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "missingKey", objectType: ProjectModelItemClass.self).description
        })
    }

    @Test
    func parseValueForKeyAsBool() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        let trueValue: Bool = try ProjectModelItemClass.parseValueForKeyAsBool("trueKey", pifDict: pifDict)
        #expect(trueValue)
        let falseValue: Bool = try ProjectModelItemClass.parseValueForKeyAsBool("falseKey", pifDict: pifDict)
        #expect(!falseValue)
        let missingFalseValue: Bool = try ProjectModelItemClass.parseValueForKeyAsBool("missingKey", pifDict: pifDict)
        #expect(!missingFalseValue)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsBool("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "String", destinationType: "Bool").description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsBool("stringKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.invalidEnumValue(keyName: "stringKey", objectType: ProjectModelItemClass.self, actualValue: "aValue", destinationType: PIFBoolValue.self).description
        })
    }

    @Test
    func parseValueForKeyAsArrayOfPropertyListItems() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the required version.
        let requiredValue = try ProjectModelItemClass.parseValueForKeyAsArrayOfPropertyListItems("arrayOfItemsKey", pifDict: pifDict)
        #expect(requiredValue.count == 3)
        guard case .plDict(let firstItem) = requiredValue[0] else {
            Issue.record("first item of property list array is not a dictionary")
            return
        }
        guard case .plString("xib-fileReference-guid")? = firstItem["guid"] else {
            Issue.record("first item of property list array does not have a guid")
            return
        }
        guard case .plDict(let secondItem) = requiredValue[1] else {
            Issue.record("second item of property list array is not a dictionary")
            return
        }
        guard case .plString("fr-strings-fileReference-guid")? = secondItem["guid"] else {
            Issue.record("first item of property list array does not have a guid")
            return
        }
        guard case .plDict(let thirdItem) = requiredValue[2] else {
            Issue.record("third item of property list array is not a dictionary")
            return
        }
        guard case .plString("some-fileGroup-guid")? = thirdItem["guid"] else {
            Issue.record("first item of property list array does not have a guid")
            return
        }

        // Test the optional version.
        let presentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfPropertyListItems("arrayOfItemsKey", pifDict: pifDict)
        #expect(presentValue?.count == 3)
        guard case .plDict(let anotherFirstItem)? = presentValue?[0] else {
            Issue.record("first item of optional property list array is not a dictionary")
            return
        }
        guard case .plString("xib-fileReference-guid")? = anotherFirstItem["guid"] else {
            Issue.record("first item of optional property list array does not have a guid")
            return
        }
        guard case .plDict(let anotherSecondItem)? = presentValue?[1] else {
            Issue.record("second item of optional property list array is not a dictionary")
            return
        }
        guard case .plString("fr-strings-fileReference-guid")? = anotherSecondItem["guid"] else {
            Issue.record("first item of optional property list array does not have a guid")
            return
        }
        guard case .plDict(let anotherThirdItem)? = presentValue?[2] else {
            Issue.record("third item of optional property list array is not a dictionary")
            return
        }
        guard case .plString("some-fileGroup-guid")? = anotherThirdItem["guid"] else {
            Issue.record("first item of optional property list array does not have a guid")
            return
        }

        let absentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfPropertyListItems("missingKey", pifDict: pifDict)
        #expect(absentValue == nil)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfPropertyListItems("stringKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Array", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfPropertyListItems("stringKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Array", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfPropertyListItems("missingKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "missingKey", objectType: ProjectModelItemClass.self).description
        })
    }

    @Test
    func parseValueForKeyAsArrayOfProjectModelItems() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the required version.
        let requiredValue: [SWBCore.Reference] = try Reference.parseValueForKeyAsArrayOfProjectModelItems("arrayOfItemsKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        #expect(requiredValue.count == 3)
        #expect(requiredValue[0].guid == "xib-fileReference-guid")
        #expect(requiredValue[1].guid == "fr-strings-fileReference-guid")
        #expect(requiredValue[2].guid == "some-fileGroup-guid")

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfProjectModelItems("stringKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Array", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfProjectModelItems("missingKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "missingKey", objectType: ProjectModelItemClass.self).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfProjectModelItems("arrayOfStringsKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectTypeInArray(keyName: "arrayOfStringsKey", objectType: ProjectModelItemClass.self, expectedType: "Dictionary").description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfProjectModelItems("arrayOfEmptyDictsKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "guid", objectType: Reference.self).description
        })
    }

    @Test
    func parseValueForKeyAsOptionalArrayOfProjectModelItems() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the optional version.
        let presentValue: [SWBCore.Reference]? = try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfProjectModelItems("arrayOfItemsKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        #expect(presentValue?.count == 3)
        #expect(presentValue?[0].guid == "xib-fileReference-guid")
        #expect(presentValue?[1].guid == "fr-strings-fileReference-guid")
        #expect(presentValue?[2].guid == "some-fileGroup-guid")

        let absentValue: [SWBCore.Reference]? = try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfProjectModelItems("missingKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        #expect(absentValue == nil)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfProjectModelItems("stringKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Array", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfProjectModelItems("arrayOfStringsKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectTypeInArray(keyName: "arrayOfStringsKey", objectType: ProjectModelItemClass.self, expectedType: "Dictionary").description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfProjectModelItems("arrayOfEmptyDictsKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "guid", objectType: Reference.self).description
        })
    }

    @Test
    func parseValueForKeyAsArrayOfStrings() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the required version.
        let requiredValue = try ProjectModelItemClass.parseValueForKeyAsArrayOfStrings("arrayOfStringsKey", pifDict: pifDict)
        #expect(requiredValue.count == 5)
        #expect(requiredValue == [ "one", "two", "three", "four", "five" ])

        // Test the optional version.
        let presentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfStrings("arrayOfStringsKey", pifDict: pifDict)
        #expect(presentValue?.count == 5)
        #expect(presentValue == [ "one", "two", "three", "four", "five" ])

        let absentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfStrings("missingKey", pifDict: pifDict)
        #expect(absentValue == nil)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfStrings("stringKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Array", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfStrings("stringKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Array", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfStrings("missingKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "missingKey", objectType: ProjectModelItemClass.self).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsArrayOfStrings("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectTypeInArray(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "String").description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsArrayOfStrings("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectTypeInArray(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "String").description
        })
    }

    @Test
    func parseValueForKeyAsPIFDictionary() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the required version.
        let requiredValue = try ProjectModelItemClass.parseValueForKeyAsPIFDictionary("dictionaryKey", pifDict: pifDict)
        #expect(requiredValue.count == 3)

        // Test the optional version.
        let presentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsPIFDictionary("dictionaryKey", pifDict: pifDict)
        #expect(presentValue?.count == 3)

        let absentValue = try ProjectModelItemClass.parseOptionalValueForKeyAsPIFDictionary("missingKey", pifDict: pifDict)
        #expect(absentValue == nil)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsPIFDictionary("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "Dictionary", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsPIFDictionary("arrayOfItemsKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "arrayOfItemsKey", objectType: ProjectModelItemClass.self, expectedType: "Dictionary", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsPIFDictionary("missingKey", pifDict: pifDict)
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "missingKey", objectType: ProjectModelItemClass.self).description
        })
    }

    @Test
    func parseValueForKeyAsProjectModelItem() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the required version.
        let _ = try FileGroup.parseValueForKeyAsProjectModelItem("fileGroupKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try FileGroup(fromDictionary: $0, withPIFLoader: pifLoader, isRoot: false) })

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsProjectModelItem("stringKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Dictionary", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsProjectModelItem("missingKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "missingKey", objectType: ProjectModelItemClass.self).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseValueForKeyAsProjectModelItem("dictionaryKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "guid", objectType: Reference.self).description
        })
    }

    @Test
    func parseValueForKeyAsOptionalProjectModelItem() throws {
        guard case .plDict(let pifDict) = try getTestPlist() else {
            Issue.record("property list is not a dictionary")
            return
        }

        // Test the optional version.
        let presentValue: SWBCore.FileGroup? = try FileGroup.parseOptionalValueForKeyAsProjectModelItem("fileGroupKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try FileGroup(fromDictionary: $0, withPIFLoader: pifLoader, isRoot: false) })
        #expect(presentValue != nil)

        let absentValue: SWBCore.FileGroup? = try FileGroup.parseOptionalValueForKeyAsProjectModelItem("missingKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try FileGroup(fromDictionary: $0, withPIFLoader: pifLoader, isRoot: false) })
        #expect(absentValue == nil)

        // Test failure cases.
        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsProjectModelItem("stringKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.incorrectType(keyName: "stringKey", objectType: ProjectModelItemClass.self, expectedType: "Dictionary", destinationType: nil).description
        })

        #expect(performing: {
            try ProjectModelItemClass.parseOptionalValueForKeyAsProjectModelItem("dictionaryKey", pifDict: pifDict, pifLoader: pifLoader, construct: { try Reference(fromDictionary: $0, withPIFLoader: pifLoader) })
        }, throws: { error in
            (error as? PIFParsingError)?.description == PIFParsingError.missingRequiredKey(keyName: "guid", objectType: Reference.self).description
        })
    }

    @Test
    func pIFSchemaVersionParsing() throws {
        let _ = try parsePIFVersion("NOVERSION")

        // re-enable once rdar://54261777 is implemented
        //        XCTAssertThrowsError(try parsePIFVersion("INVALID"), "Missing version number") { error in
        //            XCTAssertEqual(String(describing: error), "no PIF version found in signature: INVALID")
        //        }

        //        XCTAssertThrowsError(try parsePIFVersion("INVALID@vxx_"), "Invalid version number") { error in
        //            XCTAssertEqual(String(describing: error), "no PIF version found in signature: INVALID@vxx_")
        //        }

        #expect(try parsePIFVersion("v12_") == 12)
        #expect(try parsePIFVersion("WORKSPACE@v12_v13_v14") == 12)
    }
}


// MARK: - Test cases for loading PIF items in isolation

@Suite fileprivate struct PIFLoadingUnitTests {
    /// A mock PIF loader.
    private let pifLoader = PIFLoader(data: .plArray([]), namespace: BuiltinMacros.namespace)

    @Test
    func loadingWorkspace() throws {
        let testWorkspaceData: [String: any PropertyListItemConvertible] = [
            "guid": "some-workspace-guid",
            "name": "aWorkspace",
            "path": Path.root.join("tmp/aWorkspace.xcworkspace/contents.xcworkspacedata").str,
            "projects": [] as [String],
        ]

        // Convert the test data into a property list, then read the workspace from it.
        let workspacePlist = PropertyListItem(testWorkspaceData)
        guard case .plDict(let workspacePIF) = workspacePlist else {
            Issue.record("property list is not a dictionary")
            return
        }
        let workspace = try Workspace( fromDictionary: workspacePIF, signature: "mock", withPIFLoader: pifLoader )

        // Examine the workspace.
        #expect(workspace.guid == "some-workspace-guid")
        #expect(workspace.name == "aWorkspace")
        #expect(workspace.path == Path.root.join("tmp/aWorkspace.xcworkspace/contents.xcworkspacedata"))
        #expect(workspace.projects.isEmpty)

        #expect("\(workspace)" == "Workspace<some-workspace-guid:aWorkspace:\(Path.root.join("tmp/aWorkspace.xcworkspace/contents.xcworkspacedata").str):0 projects>")
    }

    @Test
    func loadingProject() throws {
        let testProjectData: [String: any PropertyListItemConvertible] = [
            "guid": "some-project-guid",
            "path": "/tmp/SomeProject/aProject.xcodeproj",
            "projectDirectory": "/tmp/SomeOtherPlace",
            "targets": [] as [String],
            "groupTree": [
                "guid": "some-fileGroup-guid",
                "type": "group",
                "name": "SomeFiles",
                "sourceTree": "PROJECT_DIR",
                "path": "/tmp/SomeProject/SomeFiles",
            ],
            "buildConfigurations": [] as [String],
            "defaultConfigurationName": "Debug",
            "developmentRegion": "English",
        ]

        // Convert the test data into a property list, then read the project from it.
        let projectPlist = PropertyListItem(testProjectData)
        guard case .plDict(let projectPIF) = projectPlist else {
            Issue.record("property list is not a dictionary")
            return
        }
        let project = try Project(fromDictionary: projectPIF, signature: "mock", withPIFLoader: pifLoader )

        // Examine the project.
        #expect(project.guid == "some-project-guid")
        #expect(project.xcodeprojPath == Path("/tmp/SomeProject/aProject.xcodeproj"))
        #expect(project.sourceRoot == Path("/tmp/SomeOtherPlace"))
        #expect(project.xcodeprojPath.basename == "aProject.xcodeproj")
        #expect(project.name == "aProject")
        #expect(project.targets.isEmpty)
        #expect(project.groupTree.guid == "some-fileGroup-guid")
        #expect(project.buildConfigurations.isEmpty)
        #expect(project.defaultConfigurationName == "Debug")
        #expect(project.developmentRegion == "English")
    }

    @Test
    func loadingIndirect() throws {
        let testWorkspaceData: [String: PropertyListItem] = [
            "guid": "some-workspace-guid",
            "name": "aWorkspace",
            "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
            "projects": ["PROJECT"],
        ]
        let testProjectData: [String: PropertyListItem] = [
            "guid": "some-project-guid",
            "path": "/tmp/SomeProject/aProject.xcodeproj",
            "targets": [],
            "groupTree": [
                "guid": "some-fileGroup-guid",
                "type": "group",
                "name": "SomeFiles",
                "sourceTree": "PROJECT_DIR",
                "path": "/tmp/SomeProject/SomeFiles",
            ],
            "buildConfigurations": [],
            "defaultConfigurationName": "Debug",
            "developmentRegion": "English",
        ]
        let testData: [[String: PropertyListItem]] = [
            [
                "signature": "WORKSPACE",
                "type": "workspace",
                "contents": .init(testWorkspaceData),
            ],
            [
                "signature": "PROJECT",
                "type": "project",
                "contents": .init(testProjectData),
            ]
        ]

        let loader = PIFLoader(data: .init(testData), namespace: BuiltinMacros.namespace)
        let workspace = try loader.load(workspaceSignature: "WORKSPACE")

        // Check the workspace.
        #expect(workspace.name == "aWorkspace")
        #expect(workspace.projects.count == 1)

        // Examine the project.
        guard let project = workspace.projects.only else {
            Issue.record()
            return
        }
        #expect(project.name == "aProject")
        #expect(project.targets.isEmpty)
    }

    @Test
    func loadingFileReference() throws {
        let testFileRefData: [String: any PropertyListItemConvertible] = [
            "guid": "some-fileReference-guid",
            "type": "file",
            "sourceTree": "<absolute>",
            "path": "/tmp/SomeProject/SomeProject/ClassOne.m",
            "fileType": "sourcecode.c.objc",
            "fileTextEncoding": "utf-8",
        ]

        // Convert the test data into a property list, then read the file reference from it.
        let fileRefPlist = PropertyListItem(testFileRefData)
        guard case .plDict(let fileRefPIF) = fileRefPlist else {
            Issue.record("property list is not a dictionary")
            return
        }
        let fileRef = try #require(GroupTreeReference.parsePIFDictAsReference(fileRefPIF, pifLoader: pifLoader, isRoot: true) as? SWBCore.FileReference)

        // Examine the file reference.
        #expect(fileRef.guid == "some-fileReference-guid")
        #expect(fileRef.sourceTree == SourceTree.absolute)
        #expect(fileRef.path.stringRep == "/tmp/SomeProject/SomeProject/ClassOne.m")
        #expect(fileRef.fileTypeIdentifier == "sourcecode.c.objc")
        #expect(fileRef.regionVariantName == nil)
        #expect(fileRef.fileTextEncoding == FileTextEncoding.utf8)
    }

    @Test
    func loadingFileGroup() throws {
        let testFileGroupData: [String: any PropertyListItemConvertible] = [
            "guid": "some-fileGroup-guid",
            "type": "group",
            "name": "SomeFiles",
            "sourceTree": "PROJECT_DIR",
            "path": "/tmp/SomeProject/SomeProject",
            "children": [
                [
                    "guid": "first-fileReference-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "ClassOne.m",
                    "fileType": "sourcecode.c.objc",
                ],
                [
                    "guid": "second-fileReference-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "ClassOne.h",
                    "fileType": "sourcecode.c.h",
                ],
            ],
        ]

        // Convert the test data into a property list, then read the file group from it.
        let fileGroupPlist = PropertyListItem(testFileGroupData)
        guard case .plDict(let fileGroupPIF) = fileGroupPlist else {
            Issue.record("property list is not a dictionary")
            return
        }
        let fileGroup = try #require(GroupTreeReference.parsePIFDictAsReference(fileGroupPIF, pifLoader: pifLoader, isRoot: true) as? SWBCore.FileGroup)

        // Examine the file group.
        #expect(fileGroup.guid == "some-fileGroup-guid")
        #expect(fileGroup.name == "SomeFiles")
        #expect(fileGroup.sourceTree == SourceTree.buildSetting("PROJECT_DIR"))
        #expect(fileGroup.path.stringRep == "/tmp/SomeProject/SomeProject")
        #expect(fileGroup.children.count == 2)

        // Examine its children
        if let fileRef = try? #require(fileGroup.children.first as? SWBCore.FileReference) {
            #expect(fileRef.guid == "first-fileReference-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "ClassOne.m")
            #expect(fileRef.fileTypeIdentifier == "sourcecode.c.objc")
            #expect(fileRef.regionVariantName == nil)
        }
        if let fileRef = try? #require(fileGroup.children[1] as? SWBCore.FileReference) {
            #expect(fileRef.guid == "second-fileReference-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "ClassOne.h")
            #expect(fileRef.fileTypeIdentifier == "sourcecode.c.h")
            #expect(fileRef.regionVariantName == nil)
        }
    }

    @Test
    func loadingVersionGroup() throws {
        let testVersionGroupData: [String: any PropertyListItemConvertible] = [
            "guid": "some-versionGroup-guid",
            "type": "versionGroup",
            "sourceTree": "PROJECT_DIR",
            "path": "CoreData.xcdatamodeld",
            "fileType": "wrapper.xcdatamodel",
            "children": [
                [
                    "guid": "first-versionedFile-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "CoreData-1.xcdatamodel",
                    "fileType": "wrapper.xcdatamodel",
                ],
                [
                    "guid": "second-versionedFile-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "CoreData-2.xcdatamodel",
                    "fileType": "wrapper.xcdatamodel",
                ],
            ],
        ]

        // Convert the test data into a property list, then read the file group from it.
        let versionGroupPlist = PropertyListItem(testVersionGroupData)
        guard case .plDict(let versionGroupPIF) = versionGroupPlist else {
            Issue.record("property list is not a dictionary")
            return
        }
        let versionGroup = try #require(try GroupTreeReference.parsePIFDictAsReference(versionGroupPIF, pifLoader: pifLoader, isRoot: true) as? SWBCore.VersionGroup)

        // Examine the file group.
        #expect(versionGroup.guid == "some-versionGroup-guid")
        #expect(versionGroup.sourceTree == SourceTree.buildSetting("PROJECT_DIR"))
        #expect(versionGroup.path.stringRep == "CoreData.xcdatamodeld")
        #expect(versionGroup.children.count == 2)

        // Examine its children
        if let fileRef = try? #require(versionGroup.children[0] as? SWBCore.FileReference) {
            #expect(fileRef.guid == "first-versionedFile-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "CoreData-1.xcdatamodel")
            #expect(fileRef.fileTypeIdentifier == "wrapper.xcdatamodel")
            #expect(fileRef.regionVariantName == nil)
        }
        if let fileRef = try? #require(versionGroup.children[1] as? SWBCore.FileReference) {
            #expect(fileRef.guid == "second-versionedFile-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "CoreData-2.xcdatamodel")
            #expect(fileRef.fileTypeIdentifier == "wrapper.xcdatamodel")
            #expect(fileRef.regionVariantName == nil)
        }
    }

    @Test
    func loadingVersionGroupNoChildren() throws {
        let testVersionGroupData: [String: any PropertyListItemConvertible] = [
            "guid": "some-versionGroup-guid",
            "type": "versionGroup",
            "sourceTree": "PROJECT_DIR",
            "path": "CoreData.xcdatamodeld",
            "fileType": "wrapper.xcdatamodel",
        ]

        // Convert the test data into a property list, then read the file group from it.
        let versionGroupPlist = PropertyListItem(testVersionGroupData)
        let versionGroupPIF = try #require(versionGroupPlist.dictValue, "property list is not a dictionary")
        let versionGroup = try #require(GroupTreeReference.parsePIFDictAsReference(versionGroupPIF, pifLoader: pifLoader, isRoot: true) as? SWBCore.VersionGroup)

        // Examine the file group.
        #expect(versionGroup.guid == "some-versionGroup-guid")
        #expect(versionGroup.sourceTree == SourceTree.buildSetting("PROJECT_DIR"))
        #expect(versionGroup.path.stringRep == "CoreData.xcdatamodeld")
        #expect(versionGroup.children.count == 0)
    }

    @Test
    func loadingVariantGroup() throws {
        let variantGroupPIF: [String: PropertyListItem] = [
            "guid": "some-variantGroup-guid",
            "type": "variantGroup",
            "name": "Thingy.xib",
            "sourceTree": "<group>",
            "path": "",
            "children": [
                [
                    "guid": "xib-fileReference-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "Thingy.xib",
                    "fileType": "file.xib",
                ],
                [
                    "guid": "fr-strings-fileReference-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "Thingy.strings",
                    "fileType": "text.plist.strings",
                    "regionVariantName": "fr",
                ],
                [
                    "guid": "de-strings-fileReference-guid",
                    "type": "file",
                    "sourceTree": "<group>",
                    "path": "Thingy.strings",
                    "fileType": "text.plist.strings",
                    "regionVariantName": "de",
                ],
            ],
        ]

        // Convert the test data into a property list, then read the variant group from it.
        let variantGroup = try #require(GroupTreeReference.parsePIFDictAsReference( variantGroupPIF, pifLoader: pifLoader, isRoot: true) as? SWBCore.VariantGroup)

        // Examine the variant group.
        #expect(variantGroup.guid == "some-variantGroup-guid")
        #expect(variantGroup.name == "Thingy.xib")

        // Examine its children, the xib and its localized strings files
        if let fileRef = try? #require(variantGroup.children[0] as? SWBCore.FileReference) {
            #expect(fileRef.guid == "xib-fileReference-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "Thingy.xib")
            #expect(fileRef.fileTypeIdentifier == "file.xib")
            #expect(fileRef.regionVariantName == nil)
        }
        if let fileRef = try? #require(variantGroup.children[1] as? SWBCore.FileReference) {
            #expect(fileRef.guid == "fr-strings-fileReference-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "Thingy.strings")
            #expect(fileRef.fileTypeIdentifier == "text.plist.strings")
            #expect(fileRef.regionVariantName == "fr")
        }
        if let fileRef = try? #require(variantGroup.children[2] as? SWBCore.FileReference) {
            #expect(fileRef.guid == "de-strings-fileReference-guid")
            #expect(fileRef.sourceTree == SourceTree.groupRelative)
            #expect(fileRef.path.stringRep == "Thingy.strings")
            #expect(fileRef.fileTypeIdentifier == "text.plist.strings")
            #expect(fileRef.regionVariantName == "de")
        }
    }

    @Test
    func loadingBuildConfiguration() throws {
        let xcconfigFileRefPIF: [String: PropertyListItem] = [
            "guid": "some-xcconfig-fileReference-guid",
            "type": "file",
            "sourceTree": "PROJECT_DIR",
            "path": "/tmp/SomeProject/SomeProject/Settings.xcconfig",
            "fileType": "xcode.lang.xcconfig",
        ]

        // Convert the test data into a property list, then read the xcconfig file reference from it.
        let xcconfigFileRef = try FileReference(fromDictionary: xcconfigFileRefPIF, withPIFLoader: pifLoader, isRoot: true)

        // Now we can perform our build configuration test.
        let buildConfigurationPIF: [String: PropertyListItem] = [
            "guid": "some-buildConfiguration-guid",
            "name": "Debug",
            "baseConfigurationFileReference": "some-xcconfig-fileReference-guid",
            "buildSettings": [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "INFOPLIST_FILE": "CocoaApp/Info.plist",
                "GCC_PREPROCESSOR_DEFINITIONS": [
                    "DEBUG=1",
                    "$(inherited)",
                ]],
        ]

        // Convert the test data into a property list, then read the build configuration from it.
        let buildConfiguration = try BuildConfiguration(fromDictionary: buildConfigurationPIF, withPIFLoader: pifLoader)

        // Examine the build configuration.
        #expect(buildConfiguration.name == "Debug")
        #expect(buildConfiguration.baseConfigurationFileReferenceGUID == xcconfigFileRef.guid)
        #expect(buildConfiguration.buildSettings.valueAssignments.count == 3)
        #expect(buildConfiguration.buildSettings.lookupMacro(BuiltinMacros.PRODUCT_NAME)?.expression.stringRep == "$(TARGET_NAME)")
        #expect(buildConfiguration.buildSettings.lookupMacro(BuiltinMacros.INFOPLIST_FILE)?.expression.stringRep == "CocoaApp/Info.plist")
        #expect(buildConfiguration.buildSettings.lookupMacro(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS)?.expression.stringRep == "DEBUG=1 $(inherited)")
    }

    /// Check a build file referencing a file.
    @Test
    func loadingBuildFile_fileReference() throws {
        let buildFilePIF: [String: PropertyListItem] = [
            "guid": "some-buildFile-guid",
            "name": "AClass.m",
            "fileReference": "some-fileReference-guid",
            "additionalCompilerOptions": ["a list of additional args, possibly including $(macro)s"],
            "codeSignOnCopy": "true",
            "removeHeadersOnCopy": "true",
        ]

        // Convert the test data into a property list, then read the build file from it.
        let buildFile = try BuildFile(fromDictionary: buildFilePIF, withPIFLoader: pifLoader)

        // Examine the build file.
        #expect(buildFile.additionalArgs?.stringRep == "a list of additional args, possibly including $(macro)s")
        #expect(buildFile.codeSignOnCopy)
        #expect(buildFile.removeHeadersOnCopy)
    }

    /// Check a build file reference a target.
    @Test
    func loadingBuildFile_targetReference() throws {
        let buildFilePIF: [String: PropertyListItem] = [
            "guid": "some-buildFile-guid",
            "name": "AClass.m",
            "targetReference": "some-target-guid",
        ]

        // Convert the test data into a property list, then read the build file from it.
        let buildFile = try BuildFile(fromDictionary: buildFilePIF, withPIFLoader: pifLoader)

        // Examine the build file.
        #expect(buildFile.guid == "some-buildFile-guid")
        guard case let .targetProduct(id) = buildFile.buildableItem else {
            Issue.record("unexpected buildable: \(buildFile.buildableItem)")
            return
        }
        #expect(id == "some-target-guid")
    }

    @Test
    func loadingBuildPhase() throws {
        do {
            let buildPhasePIF: [String: PropertyListItem] = [
                "guid": "some-sourcesBuildPhase-guid",
                "type": "com.apple.buildphase.sources",
                "buildFiles": [
                    [
                        "guid": "first-buildFile-guid",
                        "name": "ClassOne.m",
                        "fileReference": "first-fileReference-guid",
                    ],
                ],
            ]

            // Convert the test data into a property list, then read the build phase from it.
            if let buildPhase = try? #require(BuildPhase.parsePIFDictAsBuildPhase(buildPhasePIF, pifLoader: pifLoader) as? SWBCore.SourcesBuildPhase) {
                // Examine the build phase.
                #expect(buildPhase.buildFiles.count == 1)
            }
        }

        // A headers build phase
        do {
            let buildPhasePIF: [String: PropertyListItem] = [
                "guid": "some-headersBuildPhase-guid",
                "type": "com.apple.buildphase.headers",
                "buildFiles": [
                    [
                        "guid": "first-buildFile-guid",
                        "name": "ClassOne.h",
                        "fileReference": "first-fileReference-guid",
                    ],
                ],
            ]

            // Convert the test data into a property list, then read the build phase from it.
            if let buildPhase = try? #require(BuildPhase.parsePIFDictAsBuildPhase(buildPhasePIF, pifLoader: pifLoader) as? SWBCore.HeadersBuildPhase) {
                // Examine the build phase.
                #expect(buildPhase.buildFiles.count == 1)
            }
        }

        // A resources build phase
        do {
            let buildPhasePIF: [String: PropertyListItem] = [
                "guid": "some-resourcesBuildPhase-guid",
                "type": "com.apple.buildphase.resources",
                "buildFiles": [
                    [
                        "guid": "first-buildFile-guid",
                        "name": "Thingy.xib",
                        "fileReference": "first-fileReference-guid",
                    ],
                ],
            ]

            // Convert the test data into a property list, then read the build phase from it.
            if let buildPhase = try? #require(BuildPhase.parsePIFDictAsBuildPhase(buildPhasePIF, pifLoader: pifLoader) as? SWBCore.ResourcesBuildPhase) {
                // Examine the build phase.
                #expect(buildPhase.buildFiles.count == 1)
            }
        }

        // A copy files build phase
        do {
            let buildPhasePIF: [String: PropertyListItem] = [
                "guid": "some-copyFilesBuildPhase-guid",
                "type": "com.apple.buildphase.copy-files",
                "destinationSubfolder": "Resources",
                "destinationSubpath": "Subpath",
                "buildFiles": [
                    [
                        "guid": "second-buildFile-guid",
                        "name": "ClassTwo.m",
                        "fileReference": "second-fileReference-guid",
                    ],
                ],
                "runOnlyForDeploymentPostprocessing": "true",
            ]

            // Convert the test data into a property list, then read the build phase from it.
            if let buildPhase = try? #require(BuildPhase.parsePIFDictAsBuildPhase(buildPhasePIF, pifLoader: pifLoader) as? SWBCore.CopyFilesBuildPhase) {
                // Examine the build phase.
                #expect(buildPhase.destinationSubfolder.stringRep == "Resources")
                #expect(buildPhase.destinationSubpath.stringRep == "Subpath")
                #expect(buildPhase.buildFiles.count == 1)
                #expect(buildPhase.runOnlyForDeploymentPostprocessing);
            }
        }

        // A shell script build phase
        do {
            let buildPhasePIF: [String: PropertyListItem] = [
                "guid": "some-shellScriptBuildPhase-guid",
                "type": "com.apple.buildphase.shell-script",
                "name": "A Shell Script Phase",
                "shellPath": "/bin/sh",
                "scriptContents": "echo \"Nothing to do.\"\nexit 0",
                "originalObjectID": "1234512345",
                "inputFilePaths": [
                    "/tmp/foo.in",
                ],
                "outputFilePaths": [
                    "/tmp/foo.out",
                ],
                "emitEnvironment": "true",
                "runOnlyForDeploymentPostprocessing": "true",
            ]

            // Convert the test data into a property list, then read the build phase from it.
            if let buildPhase = try? #require(BuildPhase.parsePIFDictAsBuildPhase(buildPhasePIF, pifLoader: pifLoader) as? SWBCore.ShellScriptBuildPhase) {
                // Examine the build phase.
                #expect(buildPhase.guid == "some-shellScriptBuildPhase-guid")
                #expect(buildPhase.name == "A Shell Script Phase")
                #expect(buildPhase.shellPath.stringRep == "/bin/sh")
                #expect(buildPhase.scriptContents == "echo \"Nothing to do.\"\nexit 0")
                #expect(buildPhase.originalObjectID == "1234512345")
                #expect(buildPhase.inputFilePaths.count == 1)
                #expect(buildPhase.inputFilePaths.first?.stringRep == "/tmp/foo.in")
                #expect(buildPhase.outputFilePaths.count == 1)
                #expect(buildPhase.outputFilePaths.first?.stringRep == "/tmp/foo.out")
                #expect(buildPhase.emitEnvironment);
                #expect(buildPhase.runOnlyForDeploymentPostprocessing);
            }
        }
    }

    @Test
    func loadingBuildRule() throws {
        do {
            let buildRulePIF: [String: PropertyListItem] = [
                "guid": "some-typicalBuildRule-guid",
                "name": "Objective-C Files",
                "fileTypeIdentifier": "sourcecode.c.objc",
                "compilerSpecificationIdentifier": "com.apple.compilers.llvm.clang.1_0",
                "outputFilePaths": [
                    "/tmp/$(INPUT_FILE_BASE).o",
                ],
            ]

            // Convert the test data into a property list, then read the build rule from it.
            let buildRule = try BuildRule(fromDictionary: buildRulePIF, withPIFLoader: pifLoader)

            // Examine the build rule.
            #expect(buildRule.name == "Objective-C Files")

            switch buildRule.inputSpecifier {
            case let .fileType(fileTypeIdentifier):
                #expect(fileTypeIdentifier == "sourcecode.c.objc")
            case .patterns:
                Issue.record("wrong input specifier: \(buildRule.inputSpecifier)")
            }

            switch buildRule.actionSpecifier {
            case let .compiler(identifier):
                #expect(identifier == "com.apple.compilers.llvm.clang.1_0")
            case .shellScript:
                Issue.record("wrong action specifier: \(buildRule.actionSpecifier)")
            }
        }

        // A build rule using file patterns and a shell script.
        do {
            let buildRulePIF: [String: PropertyListItem] = [
                "guid": "some-scriptBuildRule-guid",
                "name": "Foo Files",
                "fileTypeIdentifier": "pattern.proxy",
                "filePatterns": "*.foo",
                "compilerSpecificationIdentifier": "com.apple.compilers.proxy.script",
                "scriptContents": "/bin/cp $(INPUT_FILE) $(OUTPUT_FILE_0)",
                "inputFilePaths": [],
                "outputFilePaths": [
                    "/tmp/$(INPUT_FILE_BASE).bar",
                ],
            ]

            // Convert the test data into a property list, then read the build rule from it.
            let buildRule = try BuildRule(fromDictionary: buildRulePIF, withPIFLoader: pifLoader)

            // Examine the build rule.
            #expect(buildRule.name == "Foo Files")

            switch buildRule.inputSpecifier {
            case let .patterns(patterns):
                #expect(patterns.first?.stringRep == "*.foo")
            case .fileType:
                Issue.record("wrong input specifier: \(buildRule.inputSpecifier)")
            }

            switch buildRule.actionSpecifier {
            case let .shellScript(contents, _, _, outputs, _, _, _):
                #expect(contents == "/bin/cp $(INPUT_FILE) $(OUTPUT_FILE_0)")
                #expect(outputs.count == 1)
                #expect(outputs[0].path.stringRep == "/tmp/$(INPUT_FILE_BASE).bar")
            case .compiler:
                Issue.record("wrong action specifier: \(buildRule.actionSpecifier)")
            }
        }
    }

    @Test
    func loadingStandardTarget() throws {
        // These file ref classes are only used for their GUIDs in this test, but the other data may be useful if the model changes in the future.
        let classOneFileRef: SWBCore.FileReference = try {
            let fileRefPIF: [String: PropertyListItem] = [
                "guid": "framework-source-fileReference-guid",
                "type": "file",
                "sourceTree": "PROJECT_DIR",
                "path": "ClassOne.m",
                "fileType": "sourcecode.c.objc",
            ]

            // Convert the test data into a property list, then read the file reference from it.
            return try FileReference(fromDictionary: fileRefPIF, withPIFLoader: pifLoader, isRoot: true)
        }()
        let classTwoFileRef: SWBCore.FileReference = try {
            let fileRefPIF: [String: PropertyListItem] = [
                "guid": "app-source-fileReference-guid",
                "type": "file",
                "sourceTree": "PROJECT_DIR",
                "path": "ClassTwo.m",
                "fileType": "sourcecode.c.objc",
            ]

            // Convert the test data into a property list, then read the file reference from it.
            return try FileReference(fromDictionary: fileRefPIF, withPIFLoader: pifLoader, isRoot: true)
        }()
        let cocoaFwkFileRef: SWBCore.FileReference = try {
            let fileRefPIF: [String: PropertyListItem] = [
                "guid": "cocoa-framework-fileReference-guid",
                "type": "file",
                "sourceTree": "<absolute>",
                "path": "/System/Library/Frameworks/Cocoa.framework",
                "fileType": "wrapper.framework",
            ]

            // Convert the test data into a property list, then read the file reference from it.
            return try FileReference(fromDictionary: fileRefPIF, withPIFLoader: pifLoader, isRoot: true)
        }()

        // Load a framework target.
        let frameworkTarget: SWBCore.StandardTarget = try {
            let testBuildConfigurationData: [String: PropertyListItem] = [
                "guid": "framework-buildConfiguration-guid",
                "name": "Debug",
                "buildSettings": [
                    "PRODUCT_NAME": "Something",
                    "INFOPLIST_FILE": "Something/Info.plist",
                ],
            ]
            let testSourcesBuildPhaseData: [String: PropertyListItem] = [
                "guid": "some-sourcesBuildPhase-guid",
                "type": "com.apple.buildphase.sources",
                "buildFiles": [
                    [
                        "guid": "framework-source-buildFile-guid",
                        "name": "FrameworkClass.m",
                        "fileReference": classOneFileRef.guid,
                    ],
                ],
            ]
            let testFrameworksBuildPhaseData: [String: PropertyListItem] = [
                "guid": "some-frameworksBuildPhase-guid",
                "type": "com.apple.buildphase.frameworks",
                "buildFiles": [
                    [
                        "guid": "cocoa-framework-buildFile-guid",
                        "name": "Cocoa.framework",
                        "fileReference": cocoaFwkFileRef.guid,
                    ],
                ],
            ]
            let testProductRefData: [String: PropertyListItem] = [
                "guid": "framework-productReference-guid",
                "type": "product",
                "name": "Something.framework",
            ]
            let targetPIF: [String: PropertyListItem] = [
                "guid": "framework-target-guid",
                "name": "Target Uno",
                "buildConfigurations": .plArray([
                    .plDict(testBuildConfigurationData),
                ]),
                "buildPhases": .plArray([
                    .plDict(testSourcesBuildPhaseData),
                    .plDict(testFrameworksBuildPhaseData),
                ]),
                "productReference": .plDict(testProductRefData),
                "buildRules": [],
                "dependencies": [],
                "productTypeIdentifier": "com.apple.product-type.framework",
            ]

            // Convert the test data into a property list, then read the target from it.
            return try StandardTarget( fromDictionary: targetPIF, signature: "mock", withPIFLoader: pifLoader )
        }()

        // Examine the framework target.
        #expect(frameworkTarget.guid == "framework-target-guid")
        #expect(frameworkTarget.name == "Target Uno")
        #expect(frameworkTarget.buildConfigurations.count == 1)
        #expect(frameworkTarget.buildPhases.count == 2)
        #expect(frameworkTarget.buildRules.isEmpty == true)
        #expect(frameworkTarget.productReference.guid == "framework-productReference-guid")
        #expect(frameworkTarget.productTypeIdentifier == "com.apple.product-type.framework")

        if let provisioningSourceData = frameworkTarget.provisioningSourceData(for: "Debug")
        {
            #expect(provisioningSourceData.configurationName == "Debug")
            #expect(provisioningSourceData.provisioningStyle == .automatic)
            #expect(provisioningSourceData.bundleIdentifierFromInfoPlist == "")
        }
        else
        {
            Issue.record("frameworkTarget does not have provisioning source data")
        }

        // Load an app target which depends on the framework target.
        let appTarget: SWBCore.StandardTarget = try {
            let testBuildConfigurationData: [String: PropertyListItem] = [
                "guid": "app-buildConfiguration-guid",
                "name": "Debug",
                "buildSettings": [
                    "PRODUCT_NAME": "CocoaApp",
                    "INFOPLIST_FILE": "CocoaApp/Info.plist",
                ],
            ]
            let testProvisioningSourceData: [String: PropertyListItem] = [
                "configurationName": "Debug",
                "provisioningStyle": 1,
                "bundleIdentifierFromInfoPlist": "CocoaApp",
            ]
            let testSourcesBuildPhaseData: [String: PropertyListItem] = [
                "guid": "app-sourcesBuildPhase-guid",
                "type": "com.apple.buildphase.sources",
                "buildFiles": [
                    [
                        "guid": "app-source-buildFile-guid",
                        "name": "ClassTwo.m",
                        "fileReference": classTwoFileRef.guid,
                    ],
                    [
                        "guid": "app-source-missing-buildFile-guid",
                        "name": "ClassThree.m",
                        "fileReference": "does-not-exist-fileReference-guid",
                    ],
                ],
            ]
            let testFrameworksBuildPhaseData: [String: PropertyListItem] = [
                "guid": "app-frameworksBuildPhase-guid",
                "type": "com.apple.buildphase.frameworks",
                "buildFiles": [
                    [
                        "guid": "cocoa-framework-buildFile-guid",
                        "name": "Cocoa.framework",
                        "fileReference": cocoaFwkFileRef.guid,
                    ],
                ],
            ]
            let testProductRefData: [String: PropertyListItem] = [
                "guid": "app-productReference-guid",
                "type": "product",
                "name": "CocoaApp.app",
            ]
            let targetPIF: [String: PropertyListItem] = [
                "guid": "app-target-guid",
                "name": "Target Dos",
                "buildConfigurations": .plArray([
                    .plDict(testBuildConfigurationData),
                ]),
                "provisioningSourceData": .plArray([
                    .plDict(testProvisioningSourceData),
                ]),
                "buildPhases": .plArray([
                    .plDict(testSourcesBuildPhaseData),
                    .plDict(testFrameworksBuildPhaseData),
                ]),
                "dependencies": [
                    ["guid": "framework-target-guid"],
                ],
                "productReference": .plDict(testProductRefData),
                "productTypeIdentifier": "com.apple.product-type.application",
                "buildRules": [] as PropertyListItem,
            ]

            // Convert the test data into a property list, then read the target from it.
            return try StandardTarget( fromDictionary: targetPIF, signature: "mock", withPIFLoader: pifLoader )
        }()

        // Examine the app target.
        #expect(appTarget.guid == "app-target-guid")
        #expect(appTarget.name == "Target Dos")
        #expect(appTarget.buildConfigurations.count == 1)
        #expect(appTarget.buildPhases.count == 2)
        #expect(appTarget.buildRules.isEmpty == true)
        #expect(appTarget.productReference.guid == "app-productReference-guid")
        #expect(appTarget.productTypeIdentifier == "com.apple.product-type.application")

        if let provisioningSourceData = appTarget.provisioningSourceData(for: "Debug")
        {
            #expect(provisioningSourceData.configurationName == "Debug")
            #expect(provisioningSourceData.provisioningStyle == .manual)
            #expect(provisioningSourceData.bundleIdentifierFromInfoPlist == "CocoaApp")
        }
        else
        {
            Issue.record("appTarget does not have provisioning source data")
        }

        // Check that the resolved dependency was loaded as expected.
        #expect(appTarget.dependencies.map { $0.guid } == [frameworkTarget.guid])

        // Check that the build phases and build files were loaded as expected.
        do {
            try #require(appTarget.buildPhases.count == 2)
            try #require(frameworkTarget.buildPhases.count == 2)

            let appSourcesBuildPhase = try #require(appTarget.buildPhases[0] as? SWBCore.SourcesBuildPhase)
            let appFrameworksBuildPhase = try #require(appTarget.buildPhases[1] as? SWBCore.FrameworksBuildPhase)
            let frameworkSourcesBuildPhase = try #require(frameworkTarget.buildPhases[0] as? SWBCore.SourcesBuildPhase)
            let frameworkFrameworksBuildPhase = try #require(frameworkTarget.buildPhases[1] as? SWBCore.FrameworksBuildPhase)

            // Because of the way reference resolution of a BuildFile.BuildableItem works, we don't have a context to resolve the build file's references to real references, so all we can do is check that the GUID is what we expect.
            func checkBuildFileRef(of buildPhase: SWBCore.BuildPhaseWithBuildFiles, fileRef: SWBCore.FileReference) throws {
                guard let buildFileRef = try? #require(buildPhase.buildFiles.first) else {
                    return
                }
                guard case let .reference(buildFileRefGuid) = buildFileRef.buildableItem else {
                    throw StubError.error("buildFileRef.buildableItem expected to be a .reference type but is not")
                }
                #expect(buildFileRefGuid == fileRef.guid)
            }
            try checkBuildFileRef(of: appSourcesBuildPhase, fileRef: classTwoFileRef)
            try checkBuildFileRef(of: appFrameworksBuildPhase, fileRef: cocoaFwkFileRef)
            try checkBuildFileRef(of: frameworkSourcesBuildPhase, fileRef: classOneFileRef)
            try checkBuildFileRef(of: frameworkFrameworksBuildPhase, fileRef: cocoaFwkFileRef)
        }
        catch {
            // Any #require failures which caused the block above to abort will have been reported by the test macro.
        }

        // Check that the product references have the expected back-references to their producing targets.
        #expect(appTarget.productReference.target == appTarget)
        #expect(frameworkTarget.productReference.target == frameworkTarget)
    }

    @Test
    func loadingAggregateTarget() throws {
        let target: SWBCore.AggregateTarget = try {
            let testBuildConfigurationData: [String: PropertyListItem] = [
                "guid": "aggregate-target-guid",
                "name": "Debug",
                "buildSettings": [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ],
            ]
            let targetPIF: [String: PropertyListItem] = [
                "guid": "aggregate-target-guid",
                "name": "Aggregate",
                "buildConfigurations": [
                    testBuildConfigurationData,
                ],
                "buildPhases": [],
                "buildRules": [],
                "dependencies": [],
            ]

            // Convert the test data into a property list, then read the target from it.
            return try AggregateTarget(fromDictionary: targetPIF, signature: "mock", withPIFLoader: pifLoader)
        }()

        // Examine the target.
        #expect(target.guid == "aggregate-target-guid")
        #expect(target.name == "Aggregate")
        #expect(target.buildConfigurations.count == 1)
    }

    @Test
    func loadingExternalTarget() throws {
        let target: SWBCore.ExternalTarget = try {
            let testBuildConfigurationData: [String: PropertyListItem] = [
                "guid": "external-buildConfiguration-guid",
                "name": "Debug",
                "buildSettings": [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ],
            ]
            let targetPIF: [String: PropertyListItem] = [
                "guid": "external-target-guid",
                "name": "External",
                "buildConfigurations": [
                    testBuildConfigurationData,
                ],
                "toolPath": "/usr/bin/make",
                "arguments": "$(ACTION)",
                "workingDirectory": "$(HOME)",
                "passBuildSettingsInEnvironment": "true",
                "dependencies": [],
            ]

            // Convert the test data into a property list, then read the target from it.
            return try ExternalTarget(fromDictionary: targetPIF, signature: "mock", withPIFLoader: pifLoader)
        }()

        // Examine the target.
        #expect(target.guid == "external-target-guid")
        #expect(target.name == "External")
        #expect(target.buildConfigurations.count == 1)
        #expect(target.toolPath.stringRep == "/usr/bin/make")
        #expect(target.arguments.stringRep == "$(ACTION)")
        #expect(target.workingDirectory.stringRep == "$(HOME)")
        #expect(target.passBuildSettingsInEnvironment == true)
    }
}

// MARK: - Tests for loading PIFs from real projects

/// These are, in fact, canned PIFs from the same projects used in IDEPIFGenerationTests.
@Suite fileprivate struct PIFLoadingFunctionalTests: CoreBasedTests {
    @Test
    func workspaceWithProject() async throws {
        // The PIF has a workspace with a single project, with three targets: An aggregate target, a standard target, and an external target.
        let testWorkspace = TestWorkspace(
            "aWorkspace",
            projects: [
                TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("SourceFile1.m"),
                            TestFile("HeaderFile1.h"),
                            TestFile("SourceFile2.m"),
                            TestFile("HeaderFile2.h"),
                            TestVariantGroup(
                                "View.xib",
                                children: [
                                    TestFile("View.xib"),
                                    TestFile("View.strings", regionVariantName: "fr"),
                                    TestFile("View.strings", regionVariantName: "de"),
                                ]
                            ),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [:]
                        ),
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "SKIP_INSTALL": "YES",
                            ]
                        ),
                    ],
                    targets: [
                        TestAggregateTarget(
                            "AggregateTarget",
                            buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")],
                            dependencies: [
                                "AppTarget",
                                "ExternalTarget",
                            ]
                        ),
                        TestStandardTarget(
                            "FwkTarget",
                            type: .framework,
                            buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")],
                            buildPhases: [
                                TestHeadersBuildPhase([
                                    "HeaderFile1.h",
                                ]),
                                TestSourcesBuildPhase([
                                    "SourceFile1.m",
                                ]),
                                TestFrameworksBuildPhase([
                                ]),
                            ]
                        ),
                        TestStandardTarget(
                            "AppTarget",
                            type: .application,
                            buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    "SourceFile2.m",
                                ]),
                                TestFrameworksBuildPhase([
                                    "FwkTarget.framework",
                                ]),
                                TestResourcesBuildPhase([
                                    "View.xib",
                                ]),
                                TestCopyFilesBuildPhase([
                                    TestBuildFile(
                                        "FwkTarget.framework",
                                        codeSignOnCopy: true,
                                        removeHeadersOnCopy: true
                                    ),
                                ], destinationSubfolder: .frameworks),
                            ],
                            dependencies: [
                                "FwkTarget",
                            ]
                        ),
                        TestExternalTarget(
                            "ExternalTarget",
                            buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")],
                            passBuildSettingsInEnvironment: true
                        ),
                    ]
                )
            ]
        )
        let workspace = try await testWorkspace.load(getCore())

        // Check the workspace.
        XCTAssertMatch(workspace.guid, .prefix("W"))
        #expect(workspace.name == "aWorkspace")
        #expect(workspace.path == Path.root.join("tmp/aWorkspace/aWorkspace.xcworkspace"))
        #expect(workspace.projects.count == 1)

        // Check the project.
        let project = workspace.projects[0]
        XCTAssertMatch(project.guid, .prefix("P"))
        #expect(project.xcodeprojPath == Path.root.join("tmp/aWorkspace/aProject/aProject.xcodeproj"))
        #expect(project.buildConfigurations.count == 2)
        #expect(project.defaultConfigurationName == "Release")
        #expect(project.developmentRegion == "English")
        #expect(project.targets.count == 4)

        // Check the group tree.
        let rootGroup = project.groupTree
        XCTAssertMatch(rootGroup.guid, .prefix("G"))
        #expect(rootGroup.parent == nil)
        #expect(rootGroup.children.count == 5)
        let sourceFileRef1 = try #require(rootGroup.children[0] as? SWBCore.FileReference)
        XCTAssertMatch(sourceFileRef1.guid, .prefix("FR"))
        #expect(sourceFileRef1.parent === rootGroup)
        let headerFileRef1 = try #require(rootGroup.children[1] as? SWBCore.FileReference)
        XCTAssertMatch(headerFileRef1.guid, .prefix("FR"))
        #expect(headerFileRef1.parent === rootGroup)
        let sourceFileRef2 = try #require(rootGroup.children[2] as? SWBCore.FileReference)
        XCTAssertMatch(sourceFileRef2.guid, .prefix("FR"))
        #expect(sourceFileRef2.parent === rootGroup)
        let headerFileRef2 = try #require(rootGroup.children[3] as? SWBCore.FileReference)
        XCTAssertMatch(headerFileRef2.guid, .prefix("FR"))
        #expect(headerFileRef2.parent === rootGroup)
        let xibVariantGroup = try #require(rootGroup.children[4] as? SWBCore.VariantGroup)
        XCTAssertMatch(xibVariantGroup.guid, .prefix("VG"))
        #expect(xibVariantGroup.parent === rootGroup)
        #expect(xibVariantGroup.children.count == 3)
        let xibFile = try #require(xibVariantGroup.children[0] as? SWBCore.FileReference)
        XCTAssertMatch(xibFile.guid, .prefix("FR"))
        #expect(xibFile.parent === xibVariantGroup)
        let stringsFile = try #require(xibVariantGroup.children[1] as? SWBCore.FileReference)
        XCTAssertMatch(stringsFile.guid, .prefix("FR"))
        #expect(stringsFile.parent === xibVariantGroup)

        // Check the targets.
        let aggregateTarget = try #require(project.targets[0] as? SWBCore.AggregateTarget)
        let appTarget = try #require(project.targets[2] as? SWBCore.StandardTarget)
        let externalTarget = try #require(project.targets[3] as? SWBCore.ExternalTarget)

        XCTAssertMatch(aggregateTarget.guid, .prefix("AT"))
        #expect(aggregateTarget.name == "AggregateTarget")
        #expect(aggregateTarget.buildPhases.count == 0)
        #expect(aggregateTarget.buildConfigurations.count == 2)
        #expect(aggregateTarget.dependencies.map { $0.guid } == [appTarget.guid, externalTarget.guid])

        let fwkTarget = try #require(project.targets[1] as? SWBCore.StandardTarget)
        XCTAssertMatch(fwkTarget.guid, .prefix("T"))
        #expect(fwkTarget.name == "FwkTarget")
        #expect(fwkTarget.buildPhases.count == 3)
        #expect(fwkTarget.buildConfigurations.count == 2)
        #expect(fwkTarget.dependencies.count == 0)
        let fwkProductReference = fwkTarget.productReference
        #expect(fwkProductReference.target == fwkTarget)

        XCTAssertMatch(appTarget.guid, .prefix("T"))
        #expect(appTarget.name == "AppTarget")
        #expect(appTarget.buildPhases.count == 4)
        #expect(appTarget.buildConfigurations.count == 2)
        #expect(appTarget.dependencies.map { $0.guid } == [fwkTarget.guid])
        #expect(appTarget.productReference.target == appTarget)

        XCTAssertMatch(externalTarget.guid, .prefix("ET"))
        #expect(externalTarget.name == "ExternalTarget")
        #expect(externalTarget.buildConfigurations.count == 2)
        #expect(externalTarget.dependencies.count == 0)
        #expect(externalTarget.toolPath.stringRep == "/usr/bin/make")
        #expect(externalTarget.arguments.stringRep == "$(ACTION)")
        #expect(externalTarget.workingDirectory.stringRep == "$(PROJECT_DIR)")
        #expect(externalTarget.passBuildSettingsInEnvironment)

        #expect([SWBCore.Target](workspace.allTargets) == [aggregateTarget, fwkTarget, appTarget, externalTarget])

        // Check the build phases of the framework target.
        let headersBuildPhase = try #require(fwkTarget.buildPhases[0] as? SWBCore.HeadersBuildPhase)
        let headerBuildFile = headersBuildPhase.buildFiles[0]
        XCTAssertMatch(headerBuildFile.guid, .prefix("BF"))
        #expect(headerBuildFile.buildableItem == .reference(guid: headerFileRef1.guid))

        let fwkSourcesBuildPhase = try #require(fwkTarget.buildPhases[1] as? SWBCore.SourcesBuildPhase)
        let fwkSourceBuildFile = fwkSourcesBuildPhase.buildFiles[0]
        XCTAssertMatch(fwkSourceBuildFile.guid, .prefix("BF"))
        #expect(fwkSourceBuildFile.buildableItem == .reference(guid: sourceFileRef1.guid))

        let fwkFrameworksBuildPhase = try #require(fwkTarget.buildPhases[2] as? SWBCore.FrameworksBuildPhase)
        #expect(fwkFrameworksBuildPhase.buildFiles.count == 0)

        // Check the build phases of the app target.
        let appSourcesBuildPhase = try #require(appTarget.buildPhases[0] as? SWBCore.SourcesBuildPhase)
        let appSourceBuildFile = appSourcesBuildPhase.buildFiles[0]
        XCTAssertMatch(appSourceBuildFile.guid, .prefix("BF"))
        #expect(appSourceBuildFile.buildableItem == .reference(guid: sourceFileRef2.guid))

        let appFrameworksBuildPhase = try #require(appTarget.buildPhases[1] as? SWBCore.FrameworksBuildPhase)
        let appFrameworkBuildFile = appFrameworksBuildPhase.buildFiles[0]
        XCTAssertMatch(appFrameworkBuildFile.guid, .prefix("BF"))
        #expect(appFrameworkBuildFile.buildableItem == .targetProduct(guid: fwkProductReference.target!.guid))

        let resourcesBuildPhase = try #require(appTarget.buildPhases[2] as? SWBCore.ResourcesBuildPhase)
        let resourceBuildFile = resourcesBuildPhase.buildFiles[0]
        XCTAssertMatch(resourceBuildFile.guid, .prefix("BF"))
        #expect(resourceBuildFile.buildableItem == .reference(guid: xibVariantGroup.guid))

        let copyFilesBuildPhase = try #require(appTarget.buildPhases[3] as? SWBCore.CopyFilesBuildPhase)
        let copyFilesBuildFile = copyFilesBuildPhase.buildFiles[0]
        #expect(copyFilesBuildPhase.destinationSubfolder.stringRep == "$(FRAMEWORKS_FOLDER_PATH)")
        #expect(copyFilesBuildPhase.destinationSubpath.stringRep == "")
        #expect(copyFilesBuildFile.buildableItem == .targetProduct(guid: fwkProductReference.target!.guid))
        #expect(copyFilesBuildFile.codeSignOnCopy)
        #expect(copyFilesBuildFile.removeHeadersOnCopy)
    }

    /// Test diagnostics generated about the integrity of the objects in a workspace.
    @Test
    func workspaceDiagnostics() async throws {
        let testWorkspace = TestWorkspace(
            "aWorkspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles", path: "Sources",
                        children: []),
                    targets: [
                        TestStandardTarget(
                            "CoreFoo",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug",
                                                       buildSettings: [
                                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                                       ]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                ]),
                                TestSourcesBuildPhase([
                                ]),
                                TestFrameworksBuildPhase([
                                ]),
                                TestFrameworksBuildPhase([
                                ]),
                                TestHeadersBuildPhase([
                                ]),
                                TestHeadersBuildPhase([
                                ]),
                                TestResourcesBuildPhase([
                                ]),
                                TestResourcesBuildPhase([
                                ]),
                            ]),
                    ]),
            ]
        )
        let workspace = try await testWorkspace.load(getCore())
        guard let project = workspace.projects.first else {
            Issue.record("failed to load the workspace - it has no project")
            return
        }
        guard let target = project.targets.first else {
            Issue.record("failed to load the workspace - its project has no target")
            return
        }
        #expect(target.errors == [])
        #expect(target.warnings == [
            "target has multiple Compile Sources build phases, which may cause it to build incorrectly - all but one should be deleted",
            "target has multiple Link Binary build phases, which may cause it to build incorrectly - all but one should be deleted",
            "target has multiple Copy Headers build phases, which may cause it to build incorrectly - all but one should be deleted",
            "target has multiple Copy Bundle Resources build phases, which may cause it to build incorrectly - all but one should be deleted",
        ])
    }
}
