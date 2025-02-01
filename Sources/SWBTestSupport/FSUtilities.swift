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

#if canImport(Darwin)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

package import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

package import SWBUtil

package extension FSProxy {
    func writePlist(_ path: Path, format: PropertyListSerialization.PropertyListFormat = .xml, _ plist: PropertyListItem) async throws {
        try await writeFileContents(path) { try $0 <<< plist.asBytes(format) }
    }

    func writePlist(_ path: Path, format: PropertyListSerialization.PropertyListFormat = .xml, _ plist: any PropertyListItemConvertible) async throws {
        try await writePlist(path, format: format, plist.propertyListItem)
    }

    func writeJSON(_ path: Path, _ plist: PropertyListItem) async throws {
        try await writeFileContents(path) { try $0 <<< plist.asJSONFragment() }
    }

    func writeJSON(_ path: Path, _ plist: any PropertyListItemConvertible) async throws {
        try await writeJSON(path, plist.propertyListItem)
    }

    func writeCoreDataModel(_ path: Path, language: CoreDataCodegenLanguage, _ entities: CoreDataEntity...) throws {
        try writeCoreDataModel(path, language: language, entities)
    }

    func writeCoreDataModel(_ path: Path, language: CoreDataCodegenLanguage, _ entities: [CoreDataEntity]) throws {
        assert(path.fileExtension == "xcdatamodel")

        #if os(macOS) || targetEnvironment(macCatalyst) || !canImport(Darwin)
        let model = XMLElement(name: "model")
        model.setAttributesWith([
            "type": "com.apple.IDECoreDataModeler.DataModel",
            "documentVersion": "1.0",
            "minimumToolsVersion": "Automatic",
            "sourceLanguage": {
                switch language {
                case .objectiveC:
                    return "Objective-C"
                case .swift:
                    return "Swift"
                }
            }(),
            "userDefinedModelVersionIdentifier": ""
        ])

        for entity in entities {
            switch entity {
            case let .entity(name):
                let entityElement = XMLElement(name: "entity")
                entityElement.setAttributesWith([
                    "name": name,
                    "representedClassName": name,
                    "syncable": "YES",
                    "codeGenerationType": "class",
                ])
                model.addChild(entityElement)
            }
        }

        try createDirectory(path, recursive: true)
        try write(path.join("contents"), contents: ByteString(XMLDocument(rootElement: model).xmlData))
        #else
        throw StubError.error("Not supported on this platform")
        #endif
    }


    func writeCoreDataModelD(_ path: Path, language: CoreDataCodegenLanguage, _ entities: CoreDataEntity...) throws {
        /// Directory hierarchy is `Model.xcdatamodeld/Model.xcdatamodel/contents`
        assert(path.fileExtension == "xcdatamodeld")
        try writeCoreDataModel(path.join("\(path.basenameWithoutSuffix).xcdatamodel"), language: language, entities)
    }

    func writeDAE(_ path: Path) throws {
        assert(path.fileExtension == "dae" || path.fileExtension == "DAE")

        try write(path, contents: ByteString(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
                <library_visual_scenes>
                    <visual_scene id="scene1"/>
                </library_visual_scenes>
                <scene>
                    <instance_visual_scene url="#scene1"/>
                </scene>
            </COLLADA>
            """))
    }

    func writeIntentDefinition(_ path: Path) async throws {
        assert(path.fileExtension == "intentdefinition")

        let plist: PropertyListItem = .plDict([
            "INEnums": .plArray([]),
            "INIntentDefinitionModelVersion": .plString("1.1"),
            "INIntentDefinitionNamespace": .plString("Ov7heq"),
            "INIntentDefinitionSystemVersion": .plString("19B82"),
            "INIntentDefinitionToolsBuildVersion": .plString("12A55a"),
            "INIntentDefinitionToolsVersion": .plString("12.0"),
            "INIntents": .plArray([
                .plDict([
                    "INIntentCategory": .plString("generic"),
                    "INIntentConfigurable": .plBool(true),
                    "INIntentDescriptionID": .plString("2SL5aD"),
                    "INIntentManagedParameterCombinations": .plDict([
                        "": .plDict([
                            "INIntentParameterCombinationSupportsBackgroundExecution": .plBool(true),
                            "INIntentParameterCombinationTitle": .plString("Test"),
                            "INIntentParameterCombinationTitleID": .plString("cKhBdn"),
                            "INIntentParameterCombinationUpdatesLinked": .plBool(true)
                        ])
                    ]),
                    "INIntentName" : .plString("Intent"),
                    "INIntentParameterCombinations": .plDict([
                        "": .plDict([
                            "INIntentParameterCombinationIsPrimary": .plBool(true),
                            "INIntentParameterCombinationSupportsBackgroundExecution": .plBool(true),
                            "INIntentParameterCombinationTitle": .plString("Test"),
                            "INIntentParameterCombinationTitleID": .plString("cKhBdn"),
                        ])
                    ]),
                    "INIntentResponse": .plDict([
                        "INIntentResponseCodes": .plArray([
                            .plDict([
                                "INIntentResponseCodeName": .plString("success"),
                                "INIntentResponseCodeSuccess": .plBool(true)
                            ]),
                            .plDict([
                                "INIntentResponseCodeName": .plString("failure")
                            ])
                        ])
                    ]),
                    "INIntentTitle": .plString("Intent"),
                    "INIntentTitleID": .plString("m2tDjz"),
                    "INIntentType": .plString("Custom"),
                    "INIntentVerb": .plString("Do")
                ])
            ]),
            "INTypes": .plArray([])
        ])

        try await writePlist(path, plist)
    }

    func writeAssetCatalog(_ path: Path) async throws {
        return try await writeAssetCatalog(path, .root)
    }

    func writeAssetCatalog(_ path: Path, _ components: AssetCatalogComponent...) async throws {
        assert(path.fileExtension == "xcassets")

        let infoDict: PropertyListItem = .plDict([
            "version": .plInt(1),
            "author": .plString("xcode")
        ])

        for component in components {
            switch component {
            case .root:
                try await writeJSON(path.join("Contents.json"), ["info": infoDict])
            case .appIcon(let iconName):
                try await writeJSON(path.join("\(iconName).appiconset/Contents.json"), [
                    "info": infoDict,
                    "images": .plArray([])
                ])
            case .imageSet(let imageSetName, let images):
                try await writeJSON(path.join("\(imageSetName).imageset/Contents.json"), [
                    "info": infoDict,
                    "images": .plArray(images.map { image in
                        return .plDict([
                            "filename": .plString(image.filename),
                            "idiom": .plString(image.idiom.rawValue),
                            "scale": .plString("\(image.scale)x")
                        ])
                    }),
                ])
            case .colorSet(let colorSetName, let colors):
                try await writeJSON(path.join("\(colorSetName).colorset/Contents.json"), [
                    "info": infoDict,
                    "colors": .plArray(colors.map { color in
                        switch color {
                        case .sRGB(let red, let green, let blue, let alpha, let idiom):
                            return .plDict([
                                "idiom": .plString(idiom.rawValue),
                                "color": .plDict([
                                    "color-space": .plString("srgb"),
                                    "components": .plDict([
                                        "red": .plDouble(red),
                                        "green": .plDouble(green),
                                        "blue": .plDouble(blue),
                                        "alpha": .plDouble(alpha)
                                    ])
                                ])
                            ])
                        }
                    })
                ])
            }
        }
    }

    func writeStoryboard(_ path: Path, _ storyboardRuntime: StoryboardRuntime) async throws {
        try await writeFileContents(path) { contents in
            assert(path.fileExtension == "storyboard")
            switch storyboardRuntime {
            case .iOS:
                contents <<< """
                <?xml version="1.0" encoding="UTF-8" standalone="no"?>
                <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="13142" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES">
                <dependencies>
                <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="12042"/>
                </dependencies>
                <scenes/>
                </document>
                """
            case .watchKit:
                assert(path.basename == "Interface.storyboard")
                contents <<< """
                <?xml version="1.0" encoding="UTF-8" standalone="no"?>
                <document type="com.apple.InterfaceBuilder.WatchKit.Storyboard" version="3.0" toolsVersion="11134" systemVersion="15F34" targetRuntime="watchKit" propertyAccessControl="none" useAutolayout="YES" useTraitCollections="YES" colorMatched="YES" initialViewController="AgC-eL-Hgc">
                <dependencies>
                <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="11106"/>
                <plugIn identifier="com.apple.InterfaceBuilder.IBWatchKitPlugin" version="11055"/>
                </dependencies>
                <scenes>
                <!--Interface Controller-->
                <scene sceneID="aou-V4-d1y">
                <objects>
                <controller id="AgC-eL-Hgc" customClass="InterfaceController" customModuleProvider="target"/>
                </objects>
                <point key="canvasLocation" x="220" y="345"/>
                </scene>
                <!--Static Notification Interface Controller-->
                <scene sceneID="AEw-b0-oYE">
                <objects>
                <notificationController id="YCC-NB-fut">
                <items>
                <label alignment="left" text="Alert Label" id="IdU-wH-bcW"/>
                </items>
                <notificationCategory key="notificationCategory" identifier="myCategory" id="JfB-70-Muf"/>
                <connections>
                <outlet property="notificationAlertLabel" destination="IdU-wH-bcW" id="JKC-fr-R95"/>
                <segue destination="4sK-HA-Art" kind="relationship" relationship="dynamicNotificationInterface" id="kXh-Jw-8B1"/>
                </connections>
                </notificationController>
                </objects>
                <point key="canvasLocation" x="220" y="643"/>
                </scene>
                <!--Notification Controller-->
                <scene sceneID="ZPc-GJ-vnh">
                <objects>
                <controller id="4sK-HA-Art" customClass="NotificationController" customModuleProvider="target"/>
                </objects>
                <point key="canvasLocation" x="468" y="643"/>
                </scene>
                </scenes>
                </document>
                """
            }
        }
    }

    func writeFramework(_ path: Path, archs: [String], alwaysLipo: Bool = false, platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, embedded: Bool? = nil, `static`: Bool = false, body: (_ contentsDir: Path, _ binaryDir: Path, _ headersDir: Path, _ resourcesDir: Path) async throws -> Void) async throws {
        assert(path.fileExtension == "framework")

        let contents: Path
        let binary: Path
        let headers: Path
        let resources: Path
        let shallow = embedded ?? (platform != .macOS && platform != .macCatalyst)
        if shallow {
            contents = path
            binary = contents
            headers = contents.join("Headers")
            resources = contents
        } else {
            contents = path.join("Versions").join("A")
            binary = contents
            headers = contents.join("Headers")
            resources = contents.join("Resources")

            try createDirectory(contents, recursive: true)

            try symlink(path.join(path.basenameWithoutSuffix), target: Path("Versions/Current/\(path.basenameWithoutSuffix)"))
            try symlink(path.join("Headers"), target: Path("Versions/Current/Headers"))
            try symlink(path.join("Resources"), target: Path("Versions/Current/Resources"))

            try symlink(path.join("Versions/Current"), target: Path("A"))
        }

        try await writePlist(resources.join("Info.plist"), [:])
        try await writeFileContents(binary.join(path.basenameWithoutSuffix)) { stream in
            try await stream <<< withTemporaryDirectory { dir in
                if `static` {
                    return try await localFS.read(InstalledXcode.currentlySelected().compileStaticLibrary(path: dir, platform: platform, infoLookup: infoLookup, archs: archs, alwaysLipo: alwaysLipo))
                } else {
                    return try await localFS.read(InstalledXcode.currentlySelected().compileDynamicLibrary(path: dir, platform: platform, infoLookup: infoLookup, archs: archs, alwaysLipo: alwaysLipo))
                }
            }
        }
        try await body(contents, binary, headers, resources)

        if self === localFS {
            if !shallow {
                _ = try await runProcess(["/usr/bin/codesign", "-s", "-", binary.join(path.basenameWithoutSuffix).str])
            }
            _ = try await runProcess(["/usr/bin/codesign", "-s", "-", (shallow ? path : contents).str])
        } else {
            try await writeFileContents(contents.join("_CodeSignature/CodeSignature")) { $0 <<< "signature" }
        }
    }

    func writeAppBundle(_ path: Path, archs: [String], alwaysLipo: Bool = false, platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, embedded: Bool? = nil, body: (_ contentsDir: Path, _ binaryDir: Path, _ resourcesDir: Path) async throws -> Void) async throws {
        assert(path.fileExtension == "app")

        let contents: Path
        let binary: Path
        let resources: Path
        if embedded ?? (platform != .macOS) {
            contents = path
            binary = contents
            resources = contents
        } else {
            contents = path.join("Contents")
            binary = contents.join("MacOS")
            resources = contents.join("Resources")
        }

        try await writeFileContents(contents.join("_CodeSignature/CodeSignature")) { $0 <<< "signature" }
        try await writePlist(contents.join("Info.plist"), [:])
        try await writeFileContents(binary.join(path.basenameWithoutSuffix)) { stream in
            try await stream <<< withTemporaryDirectory { dir in
                try await localFS.read(InstalledXcode.currentlySelected().compileExecutable(path: dir, platform: platform, infoLookup: infoLookup, archs: archs, alwaysLipo: alwaysLipo))
            }
        }
        try await writeFileContents(contents.join("PkgInfo")) { $0 <<< "APPL????" }
        try await writePlist(contents.join("version.plist"), [:])
        try await body(contents, binary, resources)
    }

    func writeImage(_ path: Path, width: Int, height: Int) throws {
        #if canImport(Darwin)
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytes = [UInt8](repeating: 0 /* black */, count: width * height * (bitsPerPixel / bitsPerComponent))
        try bytes.withUnsafeBufferPointer { pointer in
            guard let data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, pointer.baseAddress, pointer.count, kCFAllocatorNull) else {
                throw CGImageError.initializationFailed
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw CGImageError.initializationFailed
            }
            guard let provider = CGDataProvider(data: data) else {
                throw CGImageError.initializationFailed
            }
            guard let image = CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel, bytesPerRow: bytes.count / height, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue).union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false, intent: CGColorRenderingIntent.defaultIntent) else {
                throw CGImageError.initializationFailed
            }
            guard let destination = CGImageDestinationCreateWithURL(CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path.str as CFString, CFURLPathStyle.cfurlposixPathStyle, false), UTType.png.identifier as CFString, 1, nil) else {
                throw CGImageError.initializationFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        #else
        throw StubError.error("Not supported on this platform")
        #endif
    }

    func writeSimulatedProvisioningProfile(uuid: String) throws {
        try createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/\(uuid).mobileprovision"), contents: "profile")
    }

    func writeSimulatedWatchKitSupportFiles(watchosSDK: TestSDKInfo, watchSimulatorSDK: TestSDKInfo) throws {
        try createDirectory(watchosSDK.path.join("Library/Application Support/WatchKit"), recursive: true)
        try write(watchosSDK.path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try createDirectory(watchSimulatorSDK.path.join("Library/Application Support/WatchKit"), recursive: true)
        try write(watchSimulatorSDK.path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
    }

    func writeSimulatedMessagesAppSupportFiles(iosSDK: TestSDKInfo) async throws {
        try createDirectory(iosSDK.path.join("../../../Library/Application Support/MessagesApplicationStub"), recursive: true)
        try await writeAssetCatalog(iosSDK.path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub.xcassets"), .appIcon("MessagesApplicationStub"))
        try write(iosSDK.path.join("../../../Library/Application Support/MessagesApplicationStub/MessagesApplicationStub"), contents: "stub")
        try await writeStoryboard(iosSDK.path.join("../../../Library/Application Support/MessagesApplicationStub/LaunchScreen.storyboard"), .iOS)
    }

    func writeSimulatedPreviewsJITStubExecutorLibraries(sdk: TestSDKInfo) throws {
        let platformLibPath = sdk.path.join("../../../Developer/usr/lib")
        try createDirectory(platformLibPath, recursive: true)
        try write(platformLibPath.join("libPreviewsJITStubExecutor.a"), contents: "stub")
        try write(platformLibPath.join("libPreviewsJITStubExecutor_no_swift_entry_point.a"), contents: "stub")
    }

    func writeXCTRunnerApp(_ path: Path, archs: [String], platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup) async throws {
        try await writeAppBundle(path, archs: archs, platform: platform, infoLookup: infoLookup) { _, _, resourcesDir in
            try await writePlist(resourcesDir.join("RunnerEntitlements.plist"), [:])
        }
    }
}

package enum AssetCatalogIdiom: String, Sendable {
    case universal
    case mac
    case ipad
}

package enum AssetCatalogColor: Sendable {
    case sRGB(red: Double, green: Double, blue: Double, alpha: Double, idiom: AssetCatalogIdiom)
}

package struct AssetCatalogImage: Sendable {
    let filename: String
    let scale: Int
    let idiom: AssetCatalogIdiom

    package init(filename: String, scale: Int, idiom: AssetCatalogIdiom) {
        self.filename = filename
        self.scale = scale
        self.idiom = idiom
    }
}

package enum AssetCatalogComponent: Sendable {
    case root
    case appIcon(_ name: String)
    case imageSet(_ name: String, _ images: [AssetCatalogImage])
    case colorSet(_ name: String, _ colors: [AssetCatalogColor])
}

package enum StoryboardRuntime: Sendable {
    case iOS
    case watchKit
}

package enum CoreDataCodegenLanguage: Sendable {
    case objectiveC
    case swift
}

package enum CoreDataEntity: Sendable {
    case entity(_ name: String)
}

fileprivate enum CGImageError: Error {
    case initializationFailed
}
