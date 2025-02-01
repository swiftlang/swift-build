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
@_spi(Testing) import SWBTaskExecution

import SWBCore
import SWBUtil

@Suite
fileprivate struct TestValidateProductTaskAction {
    private static func loadiPadMultiTaskingSplitViewTestData(sourceLocation: SourceLocation = #_sourceLocation) throws -> PropertyListItem {
        let testDataFilePath = try #require(Bundle.module.url(forResource: "product-validation-ipad-multitasking-splitview", withExtension: "plist", subdirectory: "TestData"), sourceLocation: sourceLocation).filePath
        do {
            return try PropertyList.fromPath(testDataFilePath, fs: localFS)
        } catch {
            throw StubError.error("Could not read test data from file: \(testDataFilePath.str)")
        }
    }

    private func runiPadMultiTaskingSplitViewTest(_ idx: Int, _ testDict: [String: PropertyListItem], sourceLocation: SourceLocation = #_sourceLocation) {
        let testName = testDict["name"]?.stringValue ?? "Unnamed Test"
        guard let infoDict = testDict["info"]?.dictValue else {
            Issue.record("Test item #\(idx) does not have a valid 'info' value.", sourceLocation: sourceLocation)
            return
        }
        guard let expectedResult = testDict["success"]?.looselyTypedBoolValue else {
            Issue.record("Test item #\(idx) does not have a valid 'success' value.", sourceLocation: sourceLocation)
            return
        }
        guard let expectedWarnings = testDict["errors"]?.arrayValue?.compactMap({ $0.stringValue }) else {
            Issue.record("Test item #\(idx) does not have a valid 'errors' value.", sourceLocation: sourceLocation)
            return
        }

        let delegate = MockTaskOutputDelegate()
        let result = ValidateProductTaskAction().validateiPadMultiTaskingSplitViewSupport(infoDict, outputDelegate: delegate)
        #expect(result == expectedResult, "unexpected result for test #\(idx) (\(testName))", sourceLocation: sourceLocation)
        let warnings = Set(delegate.diagnostics.compactMap { diag -> String? in
            if diag.behavior == .warning {
                return diag.formatLocalizedDescription(.debugWithoutBehavior)
            }
            return nil
        })
        #expect(warnings == Set(expectedWarnings), "unexpected warnings for test #\(idx) (\(testName))", sourceLocation: sourceLocation)
    }

    @Test
    func iPadMultiTaskingSplitViewValidation() throws {
        for (idx, test) in (try #require(Self.loadiPadMultiTaskingSplitViewTestData().arrayValue, "top level item is not an array")).enumerated() {
            runiPadMultiTaskingSplitViewTest(idx, try #require(test.dictValue, "Test item #\(idx) is not a dictionary"))
        }
    }

    @Test
    func macOSAppStoreCategoryValidation() throws {
        do {
            let plist: [String: PropertyListItem] = [:]
            let delegate = MockTaskOutputDelegate()
            let emptyOptions = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "-infoplist-subpath", "Contents/Info.plist", "tester.app"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "macosx", targetName: "tester", schemeCommand: .archive, options: emptyOptions, outputDelegate: delegate)
            #expect(!result)
            #expect(delegate.warnings == ["warning: No App Category is set for target 'tester'. Set a category by using the General tab for your target, or by adding an appropriate LSApplicationCategory value to your Info.plist."])
        }

        do {
            let plist: [String: PropertyListItem] = ["LSApplicationCategoryType": .plString("")]
            let delegate = MockTaskOutputDelegate()
            let emptyOptions = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "tester.app", "-infoplist-subpath", "Contents/Info.plist"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "macosx", targetName: "tester", schemeCommand: .archive, options: emptyOptions, outputDelegate: delegate)
            #expect(!result)
            #expect(delegate.warnings == ["warning: No App Category is set for target 'tester'. Set a category by using the General tab for your target, or by adding an appropriate LSApplicationCategory value to your Info.plist."])
        }

        do {
            // Only the `macosx` platform is validated.
            let plist: [String: PropertyListItem] = ["LSApplicationCategoryType": .plString("")]
            let delegate = MockTaskOutputDelegate()
            let emptyOptions = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "tester.app", "-infoplist-subpath", "Info.plist"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "iphoneos", targetName: "tester", schemeCommand: .archive, options: emptyOptions, outputDelegate: delegate)
            #expect(result)
            #expect(delegate.warnings == [])
        }

        do {
            // Only validate on the `archive` command.
            let plist: [String: PropertyListItem] = [:]
            let delegate = MockTaskOutputDelegate()
            let emptyOptions = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "tester.app", "-infoplist-subpath", "Info.plist"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "iphoneos", targetName: "tester", schemeCommand: .launch, options: emptyOptions, outputDelegate: delegate)
            #expect(result)
            #expect(delegate.warnings == [])
        }

        do {
            let plist: [String: PropertyListItem] = ["LSApplicationCategoryType": .plString("Lifestyle")]
            let delegate = MockTaskOutputDelegate()
            let emptyOptions = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "tester.app", "-infoplist-subpath", "Contents/Info.plist"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "macosx", targetName: "tester", schemeCommand: .archive, options: emptyOptions, outputDelegate: delegate)
            #expect(result)
            #expect(delegate.warnings == [])
        }

        do {
            // It should be possible to validate for non-archive builds as well.
            let plist: [String: PropertyListItem] = ["LSApplicationCategoryType": .plString("Lifestyle")]
            let delegate = MockTaskOutputDelegate()
            let options = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "tester.app", "-validate-for-store", "-infoplist-subpath", "Contents/Info.plist"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "macosx", targetName: "tester", schemeCommand: .launch, options: options, outputDelegate: delegate)
            #expect(result)
            #expect(delegate.warnings == [])
        }

        do {
            let plist: [String: PropertyListItem] = ["LSApplicationCategoryType": .plString("")]
            let delegate = MockTaskOutputDelegate()
            let options = try #require(ValidateProductTaskAction.Options(AnySequence(["toolname", "tester.app", "-validate-for-store", "-infoplist-subpath", "Contents/Info.plist"]), delegate))
            let result = ValidateProductTaskAction().validateAppStoreCategory(plist, platform: "macosx", targetName: "tester", schemeCommand: .launch, options: options, outputDelegate: delegate)
            #expect(!result)
            #expect(delegate.warnings == ["warning: No App Category is set for target 'tester'. Set a category by using the General tab for your target, or by adding an appropriate LSApplicationCategory value to your Info.plist."])
        }
    }
}
