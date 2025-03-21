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

    private static let deepEmbeddedFrameworkPath = Path.root.join("MyApp.app/Contents/Frameworks/MyFramework.framework")
    private static let shallowEmbeddedFrameworkPath = Path("MyApp.app/Frameworks/MyFramework.framework")

    @Test
    func embeddedFrameworksValidationBasic() async throws {
        try await withTemporaryDirectory { tmp in
            let frameworkPath = tmp.join(Self.shallowEmbeddedFrameworkPath)
            let delegate = MockTaskOutputDelegate()
            try localFS.createDirectory(frameworkPath, recursive: true)
            try await localFS.writePlist(frameworkPath.join("Info.plist"), .plDict([
                "CFBundleIdentifier": "com.apple.Lunch",
            ]))
            let result = try ValidateProductTaskAction().validateFrameworks(at: tmp.join("MyApp.app"), isShallow: true, outputDelegate: delegate)
            #expect(result, "validation unexpectedly failed")
            #expect(delegate.errors.isEmpty)
        }
    }

    @Test
    func embeddedFrameworksValidationNoPlist() throws {
        let delegate = MockTaskOutputDelegate()
        let fs = PseudoFS()
        try fs.createDirectory(Self.deepEmbeddedFrameworkPath, recursive: true)
        let result = try ValidateProductTaskAction().validateFrameworks(at: Path.root.join("MyApp.app"), isShallow: false, outputDelegate: delegate, fs: fs)
        #expect(result == false, "validation unexpectedly succeeded")
        #expect(delegate.errors == ["error: Framework \(Self.deepEmbeddedFrameworkPath.str) did not contain an Info.plist"])
    }

    @Test
    func embeddedFrameworksValidationHaveShallowBundleFormatForDeepBundle() async throws {
        let delegate = MockTaskOutputDelegate()
        let fs = PseudoFS()
        try fs.createDirectory(Self.deepEmbeddedFrameworkPath, recursive: true)
        try await fs.writePlist(Self.deepEmbeddedFrameworkPath.join("Info.plist"), .plDict([
            "CFBundleIdentifier": "com.apple.Lunch",
        ]))
        let result = try ValidateProductTaskAction().validateFrameworks(at: Path.root.join("MyApp.app"), isShallow: false, outputDelegate: delegate, fs: fs)
        #expect(result == false, "validation unexpectedly succeeded")
        #expect(delegate.errors == ["error: Framework \(Self.deepEmbeddedFrameworkPath.str) contains Info.plist, expected Versions/Current/Resources/Info.plist since the platform does not use shallow bundles"])
    }

    @Test
    func embeddedFrameworksValidationHaveDeepBundleFormatForShallowBundle() async throws {
        let delegate = MockTaskOutputDelegate()
        let fs = PseudoFS()
        let path = Path.root.join(Self.shallowEmbeddedFrameworkPath)
        try fs.createDirectory(path, recursive: true)
        try await fs.writePlist(path.join("Versions/Current/Resources/Info.plist"), .plDict([
            "CFBundleIdentifier": "com.apple.Lunch",
        ]))
        let result = try ValidateProductTaskAction().validateFrameworks(at: Path.root.join("MyApp.app"), isShallow: true, outputDelegate: delegate, fs: fs)
        #expect(result == false, "validation unexpectedly succeeded")
        #expect(delegate.errors == ["error: Framework \(path.str) contains Versions/Current/Resources/Info.plist, expected Info.plist at the root level since the platform uses shallow bundles"])
    }

    @Test(.requireSDKs(.macOS)) // `PropertyListSerialization` crashes with an invalid plist on non-Darwin platforms.
    func embeddedFrameworksValidationInvalidInfoPlist() throws {
        try withTemporaryDirectory { tmp in
            let frameworkPath = tmp.join(Self.shallowEmbeddedFrameworkPath)
            let delegate = MockTaskOutputDelegate()
            try localFS.createDirectory(frameworkPath, recursive: true)
            try localFS.write(frameworkPath.join("Info.plist"), contents: "Lunch?")
            let result = try ValidateProductTaskAction().validateFrameworks(at: tmp.join("MyApp.app"), isShallow: true, outputDelegate: delegate)
            #expect(result == false, "validation unexpectedly succeeded")
            #expect(delegate.errors == ["error: Failed to read Info.plist of framework \(frameworkPath.str): Couldn't parse property list because the input data was in an invalid format"])
        }
    }

    @Test
    func embeddedFrameworksValidationNoBundleIdentifier() async throws {
        try await withTemporaryDirectory { tmp in
            let frameworkPath = tmp.join(Self.shallowEmbeddedFrameworkPath)
            let delegate = MockTaskOutputDelegate()
            try localFS.createDirectory(frameworkPath, recursive: true)
            try await localFS.writePlist(frameworkPath.join("Info.plist"), .plDict([
                "SomeKey": "Value",
            ]))
            let result = try ValidateProductTaskAction().validateFrameworks(at: tmp.join("MyApp.app"), isShallow: true, outputDelegate: delegate)
            #expect(result == false, "validation unexpectedly succeeded")
            #expect(delegate.errors == ["error: Framework \(frameworkPath.str) did not have a CFBundleIdentifier in its Info.plist"])
        }
    }

    @Test
    func embeddedFrameworksValidationInvalidBundleIdentifier() async throws {
        try await withTemporaryDirectory { tmp in
            let frameworkPath = tmp.join(Self.shallowEmbeddedFrameworkPath)
            let delegate = MockTaskOutputDelegate()
            try localFS.createDirectory(frameworkPath, recursive: true)
            try await localFS.writePlist(frameworkPath.join("Info.plist"), .plDict([
                "CFBundleIdentifier": "/Lunch",
            ]))
            let result = try ValidateProductTaskAction().validateFrameworks(at: tmp.join("MyApp.app"), isShallow: true, outputDelegate: delegate)
            #expect(result == false, "validation unexpectedly succeeded")
            #expect(delegate.errors == ["error: Framework \(frameworkPath.str) had an invalid CFBundleIdentifier in its Info.plist: /Lunch"])
        }
    }
}
