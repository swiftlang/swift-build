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

public import SWBCore
import SWBLibc
public import SWBUtil
import SWBProtocol
import Foundation

/// Concrete implementation of task for validating a a product.
public final class ValidateProductTaskAction: TaskAction {

    /// The parsed command line options.
    @_spi(Testing) public struct Options {

        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) <application-path>\n"
            }
        }

        enum StoreIssueTreatment {
            case treatAsWarnings
            case treatAsErrors
        }
        let verbose: Bool
        let storeIssueTreatment: StoreIssueTreatment
        let validateForStore: Bool
        let validatingArchive: Bool
        let validateEmbeddedFrameworks: Bool
        let applicationPath: Path
        let infoplistSubpath: String
        let isShallowBundle: Bool

        @_spi(Testing) public init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            let verbose = false
            let storeIssueTreatment: StoreIssueTreatment = .treatAsWarnings
            var validateForStore = false
            var validatingArchive = false
            var applicationPath: Path! = nil
            var infoplistSubpath: String! = nil
            var validateExtension = true
            var validateEmbeddedFrameworks = true
            var isShallowBundle = false

            var hadErrors = false
            func error(_ message: String) {
                outputDelegate.emitError(message)
                hadErrors = true
            }
            func warning(_ message: String) {
                outputDelegate.emitWarning(message)
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            argumentParsing:
                while let arg = generator.next() {
                    switch arg {
// Presently these options are disabled; they are only used for "offline store validation", which was disabled in the original XCWorkQueueCommandBuiltinInvocation_validationUtility and is not yet implemented here.
// When & if they are reenabled, they should be documented in emitUsage().
/*
                    case "-verbose":
                        verbose = true

                    case "-warnings":
                        storeIssueTreatment = .treatAsWarnings

                    case "-errors":
                        storeIssueTreatment = .treatAsErrors
*/
                    case "-validate-for-store":
                        validateForStore = true

                    // The default is yes, so we only need an opt-out for now. This also prevents us from having to pass in `-validate-extension` everywhere, even though that is the default behavior.
                    case "-no-validate-extension":
                        validateExtension = false

                    case "-no-validate-embedded-frameworks":
                        validateEmbeddedFrameworks = false

                    case "-shallow-bundle":
                        isShallowBundle = true

                    case "-infoplist-subpath":
                        guard let path = generator.next() else {
                            error("missing argument for option: \(arg)")
                            continue
                        }
                        infoplistSubpath = path

                    case _ where arg.hasPrefix("-"):
                        error("unrecognized option: \(arg)")

                    case _ where applicationPath == nil:
                        // Any other option is considered to be the application path.
                        applicationPath = Path(arg)

                    default:
                        // But we can only have one application path.
                        error("multiple application paths specified")
                    }
            }

            // Diagnose missing inputs.
            if applicationPath == nil || applicationPath!.isEmpty {
                error("no application path specified")
            }

            if infoplistSubpath == nil || infoplistSubpath!.isEmpty {
                error("no Info.plist path specified")
            }

            // Validate the application path.
            let ext = applicationPath.fileExtension.lowercased()
            if ext == "ipa" {
                validatingArchive = true
            }
            else if ext != "app" {
                if validateExtension {
                    error("unknown application extension '.\(ext): expected '.app' or '.ipa'")
                }
            }

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            // Initialize contents.
            self.verbose = verbose
            self.storeIssueTreatment = storeIssueTreatment
            self.validateForStore = validateForStore
            self.validatingArchive = validatingArchive
            self.validateEmbeddedFrameworks = validateEmbeddedFrameworks
            self.applicationPath = applicationPath
            self.infoplistSubpath = infoplistSubpath
            self.isShallowBundle = isShallowBundle
        }
    }

    public override class var toolIdentifier: String {
        return "validate-product"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        // Parse the arguments.
        guard let options = Options(task.commandLineAsStrings, outputDelegate) else {
            return .failed
        }

        // Make paths absolute.
        let applicationPath = task.workingDirectory.join(options.applicationPath)

        // Read the Info.plist for the application.
        let infoPlistItem: PropertyListItem
        do {
            infoPlistItem = try PropertyList.fromPath(applicationPath.join(options.infoplistSubpath), fs: executionDelegate.fs)
        }
        catch {
            outputDelegate.emitError("Failed to read Info.plist of app \(applicationPath.str): \(error.localizedDescription)")
            return .failed
        }
        guard case .plDict(let infoPlist) = infoPlistItem else {
            outputDelegate.emitError("Failed to read Info.plist of app \(applicationPath.str): Contents of file are not a dictionary")
            return .failed
        }

        // Validate the iPad multitasking/splitview support in the Info.plist.  This never causes the tool to fail, but it may emit warnings.
        validateiPadMultiTaskingSplitViewSupport(infoPlist, outputDelegate: outputDelegate)

        if let configuredTarget = task.forTarget, let platform = configuredTarget.parameters.activeRunDestination?.platform {
            // Validate that this is actually an App Store category.
            validateAppStoreCategory(infoPlist, platform: platform, targetName: configuredTarget.target.name, schemeCommand: executionDelegate.schemeCommand, options: options, outputDelegate: outputDelegate)

            // Validate compliance of embedded frameworks w.r.t. installation and App Store submission.
            if options.validateEmbeddedFrameworks {
                do {
                    let success = try validateFrameworks(at: applicationPath, isShallow: options.isShallowBundle, outputDelegate: outputDelegate)
                    return success ? .succeeded : .failed
                } catch {
                    outputDelegate.emitError("Unexpected error while validating embedded frameworks: \(error.localizedDescription)")
                    return .failed
                }
            }
        }

        return .succeeded
    }

    private static let deepBundleInfoPlistSubpath = "Versions/Current/Resources/Info.plist"
    private static let shallowBundleInfoPlistSubpath = "Info.plist"

    @_spi(Testing) public func validateFrameworks(at applicationPath: Path, isShallow: Bool, outputDelegate: any TaskOutputDelegate, fs: any FSProxy = localFS) throws -> Bool {
        let frameworksSubpath = isShallow ? "Frameworks" : "Contents/Frameworks"
        let infoPlistSubpath = isShallow ? Self.shallowBundleInfoPlistSubpath : Self.deepBundleInfoPlistSubpath

        let frameworksPath = applicationPath.join(frameworksSubpath)
        guard fs.exists(frameworksPath) else {
            return true
        }

        var frameworkPaths = [Path]()
        try fs.traverse(frameworksPath) {
            if $0.fileExtension == "framework" {
                frameworkPaths.append($0)
            }
        }

        var hasErrors = false
        for frameworkPath in frameworkPaths {
            let infoPlistPath = frameworkPath.join(infoPlistSubpath)
            guard fs.exists(infoPlistPath) else {
                // It seems reasonably common that developers mix up the formats, so we check that to be more helpful.
                if isShallow, fs.exists(frameworkPath.join(Self.deepBundleInfoPlistSubpath)) {
                    outputDelegate.emitError("Framework \(frameworkPath.str) contains \(Self.deepBundleInfoPlistSubpath), expected \(Self.shallowBundleInfoPlistSubpath) at the root level since the platform uses shallow bundles")
                } else if !isShallow, fs.exists(frameworkPath.join(Self.shallowBundleInfoPlistSubpath)) {
                    outputDelegate.emitError("Framework \(frameworkPath.str) contains \(Self.shallowBundleInfoPlistSubpath), expected \(Self.deepBundleInfoPlistSubpath) since the platform does not use shallow bundles")
                } else {
                    outputDelegate.emitError("Framework \(frameworkPath.str) did not contain an Info.plist")
                }
                hasErrors = true
                continue
            }

            let infoPlistItem: PropertyListItem
            do {
                infoPlistItem = try PropertyList.fromPath(infoPlistPath, fs: fs)
            }
            catch let error {
                outputDelegate.emitError("Failed to read Info.plist of framework \(frameworkPath.str): \(error)")
                hasErrors = true
                continue
            }
            guard case .plDict(let infoPlist) = infoPlistItem else {
                outputDelegate.emitError("Failed to read Info.plist of framework \(frameworkPath.str): Contents of file are not a dictionary")
                hasErrors = true
                continue
            }

            // We do a more thorough validation for embedded platforms since installation will otherwise be prevented with more confusing diagnostics.
            if !isShallow {
                continue
            }

            // This is being special cased since it appears we always get a dictionary even for invalid plists.
            if infoPlist.isEmpty {
                outputDelegate.emitError("Info.plist of framework \(frameworkPath.str) was empty")
                hasErrors = true
                continue
            }

            guard let rawBundleIdentifier = infoPlist["CFBundleIdentifier"], case .plString(let bundleIdentifier) = rawBundleIdentifier, !bundleIdentifier.isEmpty else {
                outputDelegate.emitError("Framework \(frameworkPath.str) did not have a CFBundleIdentifier in its Info.plist")
                hasErrors = true
                continue
            }

            if bundleIdentifier != bundleIdentifier.asLegalBundleIdentifier {
                outputDelegate.emitError("Framework \(frameworkPath.str) had an invalid CFBundleIdentifier in its Info.plist: \(bundleIdentifier)")
                hasErrors = true
            }
        }

        return !hasErrors
    }

    @_spi(Testing) @discardableResult public func validateiPadMultiTaskingSplitViewSupport(_ infoPlist: [String: PropertyListItem], outputDelegate: any TaskOutputDelegate) -> Bool {
        // Note that there is a lot of type validation which *could* be performed here (e.g., emitting an error if some value is not the expected type), but I've only copied the validation being performed in XCWorkQueueCommandBuiltinInvocation_validationUtility, from which this was ported.

        // This validation only applies to apps built for iOS 9 or later
        guard infoPlist["DTPlatformName"]?.stringValue == "iphoneos", let platformVersionStr = infoPlist["DTPlatformVersion"]?.stringValue, let platformVersion = try? Version(platformVersionStr), platformVersion >= Version(9, 0, 0) else {
            return true
        }

        // If this is not an iPad-supporting app (device family 2), then we're done.
        var supportsIpad = false
        for deviceFamily in infoPlist["UIDeviceFamily"]?.arrayValue ?? [] {
            if deviceFamily.stringValue == "2" || deviceFamily.intValue == 2 {
                supportsIpad = true
                break
            }
        }
        guard supportsIpad else {
            return true
        }

        // If UIRequiresFullScreen is true, then the app is valid.
        if infoPlist["UIRequiresFullScreen"]?.looselyTypedBoolValue ?? false {
            return true
        }

        // Remember whether we passed validation.
        var passedValidation = true

        // All device orientations must be supported.
        let supportedOrientationsInput = infoPlist["UISupportedInterfaceOrientations~ipad"]?.arrayValue ?? infoPlist["UISupportedInterfaceOrientations"]?.arrayValue ?? []
        let supportedOrientations = Set(supportedOrientationsInput.compactMap({ $0.stringValue }))
        let expectedOrientations = Set<String>(["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
        if expectedOrientations != supportedOrientations {
            outputDelegate.emitWarning("All interface orientations must be supported unless the app requires full screen.")
            passedValidation = false
        }

        var matchingLaunchStoryboard = false
        if (infoPlist["UILaunchStoryboardName~ipad"]?.stringValue ?? infoPlist["UILaunchStoryboardName"]?.stringValue) != nil {
            matchingLaunchStoryboard = true
        } else {
            let launchStoryboards = infoPlist["UILaunchStoryboards~ipad"]?.dictValue ?? infoPlist["UILaunchStoryboards"]?.dictValue ?? [:]
            if let defaultLaunchStoryboard = launchStoryboards["UIDefaultLaunchStoryboard"]?.stringValue {
                let storyboardDefs = launchStoryboards["UILaunchStoryboardDefinitions"]?.arrayValue ?? []
                let matchingStoryboardDef = storyboardDefs.first(where: { storyboardDef in
                    return storyboardDef.dictValue?["UILaunchStoryboardIdentifier"]?.stringValue == defaultLaunchStoryboard
                })
                if matchingStoryboardDef?.dictValue?["UILaunchStoryboardFile"] != nil {
                    matchingLaunchStoryboard = true
                }
            }
        }

        let deploymentTarget = infoPlist["MinimumOSVersion"]?.stringValue.map { try? Version($0) } ?? nil
        if let deploymentTarget, deploymentTarget >= Version(14) {
            var matchingLaunchConfiguration = false
            if (infoPlist["UILaunchScreen~ipad"]?.dictValue ?? infoPlist["UILaunchScreen"]?.dictValue) != nil {
                matchingLaunchConfiguration = true
            } else {
                let launchConfigs = infoPlist["UILaunchScreens~ipad"]?.dictValue ?? infoPlist["UILaunchScreens"]?.dictValue ?? [:]
                if let defaultLaunchConfig = launchConfigs["UIDefaultLaunchScreen"]?.stringValue {
                    let configDefs = launchConfigs["UILaunchScreenDefinitions"]?.arrayValue ?? []
                    let matchingConfigDef = configDefs.first(where: { configDef in
                        return configDef.dictValue?["UILaunchScreenIdentifier"]?.stringValue == defaultLaunchConfig
                    })
                    if matchingConfigDef?.dictValue != nil {
                        matchingLaunchConfiguration = true
                    }
                }
            }

            // A default launch configuration or storyboard must be provided.
            if !matchingLaunchConfiguration && !matchingLaunchStoryboard {
                outputDelegate.emitWarning("A launch configuration or launch storyboard or xib must be provided unless the app requires full screen.")
                passedValidation = false
            }
        } else {
            // A default launch storyboard must be provided.
            if !matchingLaunchStoryboard {
                outputDelegate.emitWarning("A launch storyboard or xib must be provided unless the app requires full screen.")
                passedValidation = false
            }
        }

        return passedValidation
    }

    /// Validate that there is an App Store category that is set. Note that we only do this for an "archive" action.
    @_spi(Testing) @discardableResult public func validateAppStoreCategory(_ infoPlist: [String: PropertyListItem], platform: String, targetName: String, schemeCommand: SchemeCommand?, options: Options, outputDelegate: any TaskOutputDelegate) -> Bool {
        // Note that that we could inject this logic into the validation rules so that it is tied off of the VALIDATE_PRODUCT, however, because the MacOS templates do not have VALIDATE_PRODUCT=YES for Release builds, like the iOS templates, we still won't get the behavior that we actually want. Because of this, we simply key off of a build setting created by the archive action. See rdar://problem/45590882.

        // This validation is purposefully only enabled for the archive command or if the target has opted-in to validation.
        guard schemeCommand == .archive || options.validateForStore else {
            return true
        }

        // Only run this validation for MacOS application targets. Validation for other platforms can happen elsewhere.
        guard platform == "macosx" else {
            return true
        }

        // Note that setting an empty string for the category is not sufficient to remove this warning; it must be a category.
        // FIXME: It might be nice to also add checks here for a valid App Store category.
        guard (infoPlist["LSApplicationCategoryType"]?.stringValue ?? "") != "" else {
            outputDelegate.emitWarning("No App Category is set for target '\(targetName)'. Set a category by using the General tab for your target, or by adding an appropriate LSApplicationCategory value to your Info.plist.")
            return false
        }

        return true
    }
}
