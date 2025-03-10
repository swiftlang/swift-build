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
import SWBLibc
public import SWBCore
import SWBMacro
import struct Foundation.CharacterSet
import struct Foundation.Data
import class Foundation.PropertyListSerialization
import class Foundation.NSError

/// Concrete implementation of the Info.plist processor in-process task.
public final class InfoPlistProcessorTaskAction: TaskAction
{
    public override class var toolIdentifier: String
    {
        return "info-plist-processor"
    }

    let contextPath: Path

    // Cached properties of this task parsed from its configuration.
    private var configParsingResult: CommandResult? = nil
    private var configParsingMessages: TaskActionMessageCollection? = nil
    private var productTypeIdentifier: String? = nil
    private var inputPath: Path? = nil
    private var outputPath: Path? = nil
    private var pkgInfoPath: Path? = nil
    private var platformName: String? = nil
    private var enforceMinimumOS: Bool = false
    private var expandBuildSettings: Bool = false
    private var resourceRulesFileName: Path? = nil
    private var additionalContentFilePaths = [Path]()
    private var privacyFileContentFilePaths = [Path]()
    private var requiredArchitecture: String? = nil
    private var outputFormat: PropertyListSerialization.PropertyListFormat? = nil

    public init(_ contextPath: Path)
    {
        self.contextPath = contextPath
        super.init()
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        // Deserialize the context attachment. We discard this at the end of `performTaskAction` because it is particularly heavyweight.
        let context: InfoPlistProcessorTaskActionContext
        do {
            struct ContextDeserializerDelegate: InfoPlistProcessorTaskActionContextDeserializerDelegate {
                var namespace: SWBMacro.MacroNamespace
                let sdkRegistry: SDKRegistry
                let specRegistry: SpecRegistry
                let platformRegistry: PlatformRegistry
            }
            let deserializer = MsgPackDeserializer(try executionDelegate.fs.read(contextPath), delegate: ContextDeserializerDelegate(namespace: executionDelegate.namespace, sdkRegistry: executionDelegate.sdkRegistry, specRegistry: executionDelegate.specRegistry, platformRegistry: executionDelegate.platformRegistry))
            context = try deserializer.deserialize()
        } catch {
            outputDelegate.emitError("failed to deserialize Info.plist task context: \(error.localizedDescription)")
            return .failed
        }
        let scope = context.scope
        let productType = context.productType
        let platform = context.platform
        // Parse the arguments and cache them.  We only have to do this the first time the task is run, since the task won't change from run to run, and it cannot be run multiple times in parallel in the same process.
        if configParsingResult == nil
        {
            // The compiler won't let us just do a tuple assignment of the method return value here.  c.f <rdar://problem/24317727>
            let (result, messages) = parseConfiguration(task, context: context)
            configParsingResult = result
            configParsingMessages = messages
        }
        // We do, however, have to emit the messages and handle a bad exit code on each run.
        configParsingMessages?.emitMessages(outputDelegate)
        if configParsingResult! != .succeeded
        {
            return configParsingResult!
        }

        guard task.workingDirectory.isAbsolute else {
            outputDelegate.emitError("task working directory \(task.workingDirectory) is not an absolute path")
            return .failed
        }

        // Perform some correctness checks and make the paths absolute, if needed.
        guard let inputPath = self.inputPath?.makeAbsolute(relativeTo: task.workingDirectory) else {
            outputDelegate.emitError("no input file specified")
            return .failed
        }

        guard let outputPath = self.outputPath?.makeAbsolute(relativeTo: task.workingDirectory) else {
            outputDelegate.emitError("no output file specified")
            return .failed
        }

        // Read the property list from the file.  We assume this method will emit any appropriate messages during reading.
        // We will modify the plist in place throughout the course of the tool until we finally have the contents we want to write out.
        let contentsData: ByteString
        do
        {
            contentsData = try executionDelegate.fs.read(inputPath)
        }
        catch let e
        {
            outputDelegate.emitError("unable to read input file '\(inputPath.str)': \(e.localizedDescription)")
            return .failed
        }
        var (plist, inputFormat): (PropertyListItem, PropertyListSerialization.PropertyListFormat)
        do
        {
            (plist, inputFormat) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
        }
        catch let error as NSError
        {
            outputDelegate.emitError("unable to read property list from file: \(inputPath.str): \(error.localizedDescription)")
            return .failed
        }
        catch
        {
            outputDelegate.emitError("unable to read property list from file: \(inputPath.str): unknown error")
            return .failed
        }


        // Confirm that the property list is a dictionary.
        guard case let .plDict(plistDict) = plist else { outputDelegate.emitError("contents of file is not a dictionary: \(inputPath.str)"); return .failed }

        // Apply INFOPLIST_FILE_CONTENTS
        if let infoPlistFileContents = scope.evaluate(BuiltinMacros.INFOPLIST_FILE_CONTENTS).nilIfEmpty {
            do {
                let infoPlistFileContentsPropertyListItem = try PropertyList.fromString(infoPlistFileContents)
                guard case let .plDict(infoPlistFileContentsDict) = infoPlistFileContentsPropertyListItem else {
                    outputDelegate.emitError("contents of INFOPLIST_FILE_CONTENTS is not a dictionary")
                    return .failed
                }
                plist = .plDict(plistDict.addingContents(of: infoPlistFileContentsDict))
            }
            catch {
                outputDelegate.emitError("unable to create property list from string '\(infoPlistFileContents)': \(error.localizedDescription)")
                return .failed
            }
        }


        // Load the additional content files, if any, and merge their content into the input plist.
        for path in additionalContentFilePaths
        {
            let additionalContentResult = addAdditionalContent(from: path, &plist, context: context, executionDelegate, outputDelegate)
            guard additionalContentResult == .succeeded else
            {
                // addAdditionalContent() will have emitted any issues as it executed.
                return additionalContentResult
            }
        }

        for path in privacyFileContentFilePaths
        {
            if let privacyFile = scanForPrivacyFile(at: path, fs: executionDelegate.fs) {
                let additionalPrivacyContentResult = addAppPrivacyContent(from: privacyFile, &plist, executionDelegate, outputDelegate)
                guard additionalPrivacyContentResult == .succeeded else
                {
                    // addAppPrivacyContent() will have emitted any issues as it executed.
                    return additionalPrivacyContentResult
                }
            }
        }

        // If we were passed any required architecture, then we apply it to the value of the 'UIRequiredDeviceCapabilities' key, by setting it and removing any others.
        if requiredArchitecture != nil
        {
            let result = setRequiredDeviceCapabilities(&plist, context: context, outputDelegate: outputDelegate)
            if result != .succeeded
            {
                return result
            }
        }

        // Add the data from the additional info property in the platform to the plist.
        let additionalInfoResult = addAdditionalEntriesFromPlatform(&plist, context: context, outputDelegate: outputDelegate)
        if additionalInfoResult != .succeeded
        {
            // addAdditionalEntriesFromPlatform() will have emitted any issues as it executed.
            return additionalInfoResult
        }

        // Expand build settings in the property list if requested.  We only expand the values, not the keys.
        if expandBuildSettings {
            if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value || scope.evaluate(BuiltinMacros.GENERATE_INFOPLIST_FILE) {
                let plistDefaults = defaultInfoPlistContent(scope: scope, platform: platform, productType: productType)
                do {
                    let result = try withTemporaryDirectory(fs: executionDelegate.fs) { plistDefaultsDir -> CommandResult in
                        let plistDefaultsPath = plistDefaultsDir.join("DefaultInfoPlistContent.plist")
                        try executionDelegate.fs.write(plistDefaultsPath, contents: ByteString(PropertyListItem.plDict(plistDefaults).asBytes(.binary)))
                        return addAdditionalContent(from: plistDefaultsPath, &plist, context: context, executionDelegate, outputDelegate)
                    }

                    if result != .succeeded {
                        return result
                    }
                } catch {
                    outputDelegate.emitError("\(error)")
                    return .failed
                }
            }

            // Define overriding build settings for when we evaluate build settings in the plist.
            let lookupClosure: ((MacroDeclaration) -> MacroExpression?)?
            if case .plString(let cfBundleIdentifier)? = plist.dictValue?["CFBundleIdentifier"] {
                let cfBundleIdentifierExpr = scope.namespace.parseString(cfBundleIdentifier)
                lookupClosure = { return $0 == BuiltinMacros.CFBundleIdentifier ? cfBundleIdentifierExpr : nil }
            } else {
                lookupClosure = nil
            }

            plist = plist.byEvaluatingMacros(withScope: scope, lookup: lookupClosure)
        }

        // Elide any empty string values for a specific set of keys (bad things happen in the system if an Info.plist has an empty value for any of these keys).
        plist = plist.byElidingRecursivelyEmptyStringValuesInDictionaries(Set<String>([
            "CFBundleDevelopmentRegion",
            "CFBundleExecutable",
            "CFBundleGetInfoString",
            "CFBundleIconFile",
            "CFBundleIdentifier",
            "CFBundleName",
            "CFBundlePackageType",
            "CFBundleResourceSpecification",
            "CFBundleShortVersionString",
            "CFBundleSignature",
            "CFBundleTypeIconFile",
            "CFBundleTypeRole",
            "CFBundleVersion",
            "NSDocumentClass",
            "NSHelpFile",
            "NSHumanReadableCopyright",
            "NSMainNibFile",
            "NSPrincipalClass",
            "NSStickerSharingLevel",

            // These aren't harmful to the system if they're empty, but will cause App Store submission to fail, so elide them as well.
            "BuildMachineOSBuild",
            "DTSwiftPlaygroundsBuild",
            "DTSwiftPlaygroundsVersion",
            "DTXcode",
            "DTXcodeBuild",
        ]))

        // Convert the PropertyListItem to a Dictionary so we can inject content
        guard case .plDict(var plistDict) = plist else {
            outputDelegate.emitError("Content of file '\(inputPath.str)' is not a dictionary")
            return .failed
        }

        // Determine the build platform we're targeting.  Note that this could resolve to nil.
        let buildPlatform = context.sdk?.targetBuildVersionPlatform(sdkVariant: context.sdkVariant)

        // Compute the deployment target macro name and effective deployment target.
        // Note that this will resolve to MACOSX_DEPLOYMENT_TARGET for Mac Catalyst, because it's the macOS (not iOS) deployment target which is relevant for the purposes of Info.plist processing.  If at some point Info.plist processing needs to consider both deployment targets for Catalyst, then this will need refinement.
        let deploymentTarget: Version?
        if let deploymentTargetMacro = platform?.deploymentTargetMacro {
            deploymentTarget = try? Version(scope.evaluate(deploymentTargetMacro))
        }
        else {
            deploymentTarget = nil
        }

        // Merge content about the targeted device family into the Info.plist.
        plist = mergeUIDeviceFamilyContent(into: &plistDict, context: context, executionDelegate, outputDelegate)

        // Remove or add entries to the plist based on which platform is being targeted.  This is primarily to deal with the advent of macCatalyst, where iOS targets can be built for either iOS or macCatalyst, but it could be expanded in the future.
        let disableInfoPlistPlatformEditing = scope.evaluate(BuiltinMacros.DISABLE_INFOPLIST_PLATFORM_PROCESSING)
        if !disableInfoPlistPlatformEditing {
            plist = editPlatformSpecificEntries(in: &plistDict, outputDelegate, context: context)
        }

        if scope.evaluate(BuiltinMacros.ENABLE_THREAD_SANITIZER) && productType?.requiresStrictInfoPlistKeys(scope) != true {
            plistDict["NSBuiltWithThreadSanitizer"] = .plBool(true)
            plist = .plDict(plistDict)
        }

        // Shallow bundles must have a resource specification file (c.f. <rdar://problem/5799827>, so we add it to the additional info.
        if let resourceRulesFileName {
            plistDict["CFBundleResourceSpecification"] = .plString(resourceRulesFileName.split().1)
            plist = .plDict(plistDict)
        }

        // If we are asked to enforce the minimum OS in the Info.plist, do so. c.f. <rdar://problem/30538173>
        if enforceMinimumOS && plistDict["LSMinimumSystemVersion"] == nil {
            if let packageType = plistDict["CFBundlePackageType"], packageType == .plString("APPL") {
                if let deploymentTarget = deploymentTarget {
                    plistDict["LSMinimumSystemVersion"] = .plString(deploymentTarget.description)
                    plist = .plDict(plistDict)
                }
            }
        }

        // Codeless bundles specify a list of their statically known clients as `DTBundleClientLibraries`.
        if !context.clientLibrariesForCodelessBundle.isEmpty, scope.evaluate(BuiltinMacros.ENABLE_SDK_IMPORTS) {
            plistDict["DTBundleClientLibraries"] = .plArray(context.clientLibrariesForCodelessBundle.map { .plString($0) })
            plist = .plDict(plistDict)
        }

        // LSSupportsOpeningDocumentsInPlace has some special checks:
        // - When building for iOS, warn if it doesn't declare whether it supports either open-in-place or document browsing (see <rdar://problem/41161290>).
        // - When building for macOS, error if it sets 'LSSupportsOpeningDocumentsInPlace = NO', as that mode is not supported on macOS (see <rdar://problem/46390792>.
        //   (We can't just force it to YES because it's a declaration of behavior, so the app could still do something very bad on macOS no matter what the entry is.)
        // LSSupportsOpeningDocumentsInPlace is only relevant when document types are also defined.
        // This key is being deprecated on all platforms so all of this logic might be removed someday.
        let numDocumentTypes = plistDict["CFBundleDocumentTypes"]?.arrayValue?.count ?? 0
        if platform?.familyName == "iOS" {
            if numDocumentTypes > 0, plistDict["LSSupportsOpeningDocumentsInPlace"] == nil, plistDict["UISupportsDocumentBrowser"] == nil {
                outputDelegate.emitWarning("The application supports opening files, but doesn't declare whether it supports opening them in place. You can add an LSSupportsOpeningDocumentsInPlace entry or an UISupportsDocumentBrowser entry to your Info.plist to declare support.")
            }
        }
        else if platform?.familyName == "macOS", !disableInfoPlistPlatformEditing {
            if numDocumentTypes > 0, let sodip = plistDict["LSSupportsOpeningDocumentsInPlace"], sodip.boolValue == false {
                outputDelegate.emitError("'LSSupportsOpeningDocumentsInPlace = NO' is not supported on macOS. Either remove the entry or set it to YES, and also ensure that the application does open documents in place on macOS.")
                return .failed
            }
        }

        // Validate the contents of the plist and emit warnings and errors as necessary.  This may make some simple edits to the plist.
        if !validatePlistContents(&plistDict, buildPlatform, context.targetBuildVersionPlatforms, deploymentTarget, scope, infoLookup: executionDelegate.infoLookup, context: context, outputDelegate: outputDelegate) {
            return .failed
        }

        plist = .plDict(plistDict)

        let bytes: [UInt8]
        do {
            // Generate output data in the requested format (defaulting to the same format as the input file, if no output format has been specified).
            let effectiveOutputFormat = outputFormat ?? inputFormat

            // Foundation has not supported writing OpenStep format since Leopard (c.f. <rdar://5882332>), so in that case we default to XML format.
            bytes = try plist.asBytes(effectiveOutputFormat == .openStep ? .xml : effectiveOutputFormat)
        } catch {
            outputDelegate.emitError("unable to convert property list to output format, error: \(error.localizedDescription)")
            return .failed
        }

        do {
            _ = try executionDelegate.fs.writeIfChanged(outputPath, contents: ByteString(bytes))
        } catch {
            outputDelegate.emitError("unable to write file '\(outputPath.str)': \(error.localizedDescription)")
            return .failed
        }

        // Also generate a PkgInfo file, if we've been asked to do so.
        if let pkgInfoPath = self.pkgInfoPath?.makeAbsolute(relativeTo: task.workingDirectory) {
            do {
                try generatePackageInfo(atPath: pkgInfoPath, usingPlist: plistDict, context: context, executionDelegate, outputDelegate)
            } catch {
                return .failed
            }
        }

        return .succeeded
    }


    // MARK: Parsing the configuration


    private func parseConfiguration(_ task: any ExecutableTask, context: InfoPlistProcessorTaskActionContext) -> (CommandResult, TaskActionMessageCollection)
    {
        let messages = TaskActionMessageCollection()
        let commandLine = [String](task.commandLineAsStrings)

        var i = 1                     // Skip over the tool name
        while i < commandLine.count
        {
            let option = commandLine[i]
            switch option
            {
            case "-format":
                // The '-format' option takes a single argument: 'openstep', 'xml', or 'binary'.
                if commandLine.count > i+1
                {
                    // The argument is the format in which to write the output.
                    i += 1
                    let arg = commandLine[i]
                    if arg == "openstep"
                    {
                        outputFormat = .openStep
                    }
                    else if arg == "xml"
                    {
                        outputFormat = .xml
                    }
                    else if arg == "binary"
                    {
                        outputFormat = .binary
                    }
                    else
                    {
                        // Unrecognized argument to -format.
                        messages.addMessage(.error("unrecognized argument to \(option): '\(arg)' (use 'openstep', 'xml', or 'binary')"))
                        return (.failed, messages)
                    }
                }
                else
                {
                    // No argument to -format.
                    messages.addMessage(.error("missing argument for \(option) (use 'openstep', 'xml', or 'binary')"))
                    return (.failed, messages)
                }

            case "-genpkginfo":
                // The '-pkginfo' option takes a single argument: the path of the pkginfo file to generate.
                if commandLine.count > i+1
                {
                    // The argument is the output path.
                    i += 1
                    let arg = commandLine[i]
                    if pkgInfoPath == nil
                    {
                        // We don't already have a pkginfo path; we do now.
                        pkgInfoPath = Path(arg)
                    }
                    else
                    {
                        // We already have a pkginfo path.
                        messages.addMessage(.error("multiple pkginfo paths specified"))
                        return (.failed, messages)
                    }
                }
                else
                {
                    // No argument to -genpkginfo.
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            case "-producttype":
                if commandLine.count > i + 1 {
                    i += 1
                    let arg = commandLine[i]
                    if productTypeIdentifier == nil {
                        productTypeIdentifier = arg
                        if let productType = context.productType, arg != productType.identifier {
                            messages.addMessage(.error("argument to \(option) '\(arg)' differs from product type being built '\(productType.name)'"))
                            return (.failed, messages)
                        }
                    } else {
                        messages.addMessage(.error("multiple product types specified"))
                        return (.failed, messages)
                    }
                } else {
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            case "-platform":
                // The '-platform' option takes a single argument: the name of the platform for which the Info.plist is being generated.
                if commandLine.count > i+1
                {
                    // The argument is the platform name.
                    i += 1
                    let arg = commandLine[i]
                    if platformName == nil
                    {
                        // We don't already have a platform name; we do now.
                        platformName = arg

                        // If the platform name we were passed differs from the platform we were configured with, then emit an error.
                        if platformName! != context.platform?.name
                        {
                            messages.addMessage(.error("argument to -platform '\(platformName!)' differs from platform being targeted '\(context.platform?.name ?? "")'"))
                            return (.failed, messages)
                        }
                    }
                    else
                    {
                        // We already have a pkginfo path.
                        messages.addMessage(.error("multiple platform names specified"))
                        return (.failed, messages)
                    }
                }
                else
                {
                    // No argument to -platform.
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            case "-enforceminimumos":
                // The '-enforceminimumos' option takes no arguments.
                enforceMinimumOS = true

            case "-expandbuildsettings":
                // The '-expandbuildsettings' option takes no arguments.
                expandBuildSettings = true

            case "-resourcerulesfile":
                // The '-resourcerulesfile' option takes a single argument: the name (or path) of the resource rules file.
                if commandLine.count > i+1
                {
                    // The argument is the resource rules file.
                    i += 1
                    let arg = commandLine[i]
                    if resourceRulesFileName == nil
                    {
                        // We don't already have a resource rules file; we do now.
                        resourceRulesFileName = Path(arg)
                    }
                    else
                    {
                        // We already have a pkginfo path.
                        messages.addMessage(.error("multiple resource rules files specified"))
                        return (.failed, messages)
                    }
                }
                else
                {
                    // No argument to -resourcerulesfile.
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            case "-additionalcontentfile":
                // The '-additionalcontentfile' option takes a single argument: the name of the additional content file.  There may be more than one such file passed.
                if commandLine.count > i+1
                {
                    // The argument is the additional content file.
                    i += 1
                    let arg = commandLine[i]
                    additionalContentFilePaths.append(Path(arg))
                }
                else
                {
                    // No argument to -additionalcontentfile.
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            case "-scanforprivacyfile":
                // The '-scanforprivacyfile' option takes a single argument: the path of the path to scan for an `PrivacyInfo.xcprivacy` file.  There may be more than one such path passed.
                if commandLine.count > i+1
                {
                    i += 1
                    let arg = commandLine[i]
                    privacyFileContentFilePaths.append(Path(arg))
                }
                else
                {
                    // No argument to -scanforprivacyfile.
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            case "-requiredArchitecture":
                // The 'requiredArchitecture' option takes a single argument: An architecture to use to populate the 'UIRequiredDeviceCapabilities' key

                guard requiredArchitecture == nil else {
                    messages.addMessage(.error("multiple -requiredArchitecture specified"))
                    return (.failed, messages)
                }

                guard commandLine.count > i+1 else {
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

                // The argument is the additional content file.
                i += 1
                let arg = commandLine[i]
                requiredArchitecture = arg

            case "-o":
                // The '-o' option takes a single argument: the output path.
                if commandLine.count > i+1
                {
                    // The argument is the resource rules file.
                    i += 1
                    let arg = commandLine[i]
                    if outputPath == nil
                    {
                        // We don't already have a resource rules file; we do now.
                        outputPath = Path(arg)
                    }
                    else
                    {
                        // We already have a pkginfo path.
                        messages.addMessage(.error("multiple output files specified"))
                        return (.failed, messages)
                    }
                }
                else
                {
                    // No argument to -o.
                    messages.addMessage(.error("missing argument for \(option)"))
                    return (.failed, messages)
                }

            default:
                if option.hasPrefix("-")
                {
                    // Unknown option.
                    messages.addMessage(.error("unrecognized option: \(option)"))
                    return (.failed, messages)
                }
                else if inputPath == nil
                {
                    // If we don't already have an input path, then we use this as the input path.
                    inputPath = Path(option)
                }
                else
                {
                    // It's an input path and we already have one; that's not allowed.
                    messages.addMessage(.error("multiple input files specified"))
                    return (.failed, messages)
                }
            }

            i += 1
        }

        return (.succeeded, messages)
    }

    private let usageDescriptionStringKeys: Set<String> = [
        "NFCReaderUsageDescription",
        "NSAppleEventsUsageDescription",
        "NSAppleMusicUsageDescription",
        "NSBluetoothAlwaysUsageDescription",
        "NSBluetoothPeripheralUsageDescription",
        "NSBluetoothWhileInUseUsageDescription",
        "NSCalendarsUsageDescription",
        "NSCameraUsageDescription",
        "NSContactsUsageDescription",
        "NSDesktopFolderUsageDescription",
        "NSDocumentsFolderUsageDescription",
        "NSDownloadsFolderUsageDescription",
        "NSFaceIDUsageDescription",
        "NSFallDetectionUsageDescription",
        "NSFileProviderDomainUsageDescription",
        "NSFileProviderPresenceUsageDescription",
        "NSFocusStatusUsageDescription",
        "NSGKFriendListUsageDescription",
        "NSHealthClinicalHealthRecordsShareUsageDescription",
        "NSHealthShareUsageDescription",
        "NSHealthUpdateUsageDescription",
        "NSHomeKitUsageDescription",
        "NSIdentityUsageDescription",
        "NSLocalNetworkUsageDescription",
        "NSLocationAlwaysAndWhenInUseUsageDescription",
        "NSLocationAlwaysUsageDescription",
        "NSLocationUsageDescription",
        "NSLocationWhenInUseUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSMotionUsageDescription",
        "NSNearbyInteractionAllowOnceUsageDescription",
        "NSNearbyInteractionUsageDescription",
        "NSNetworkVolumesUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSRemindersUsageDescription",
        "NSRemovableVolumesUsageDescription",
        "NSSensorKitUsageDescription",
        "NSSiriUsageDescription",
        "NSSpeechRecognitionUsageDescription",
        "NSSystemAdministrationUsageDescription",
        "NSSystemExtensionUsageDescription",
        "NSUserTrackingUsageDescription",
        "NSVideoSubscriberAccountUsageDescription",
        "NSVoIPUsageDescription",
        "OSBundleUsageDescription",
    ]

    /// Produce a collection of default Info.plist keys based on content in the project, taking platform and product type into account.
    /// Could be done through InfoPlistAdditions properties in product types, but that would result in more duplication at this point
    private func defaultInfoPlistContent(scope: MacroEvaluationScope, platform: Platform?, productType: ProductTypeSpec?) -> [String: PropertyListItem]
    {
        var content: [String: PropertyListItem] = [:]

        // The general theory of this method is that we now have a bunch of INFOPLIST_KEY-prefixed build settings that are used to define sufficiently simple Info.plist content, and we go to those (which will either have appropriate backstops set as necessary, or be empty) to determine the content to generate.

        /// Get the macro name corresponding to the given Info.plist key name.
        /// This accommodates platform-specific override names like UISomething~ipad, which may use proper capitalization in the build setting.
        func macroNameForInfoPlistKey(key: String, prefix: String) -> String {
            let replacements = [ "~iphone": "_iPhone",
                                 "~ipad": "_iPad" ]
            var adjustedKey = key
            for (infoPlistPart, macroNamePart) in replacements {
                adjustedKey = adjustedKey.replacingOccurrences(of: infoPlistPart, with: macroNamePart)
            }
            return prefix + adjustedKey
        }

        /// Gets the value of the given setting only if it's actually set somewhere or has a non-empty default value.
        /// This is necessary because some Info.plist settings can be valid with an empty value assigned.
        func valueForInfoPlistKeyMacro(_ name: String, prefix: String = "INFOPLIST_KEY_") -> PropertyListItem? {
            let infoPlistMacroName = macroNameForInfoPlistKey(key: name, prefix: prefix)
            guard let macro = BuiltinMacros.namespace.lookupMacroDeclaration(infoPlistMacroName) else {
                return nil
            }

            let isAssigned = scope.table.contains(macro)
            let isEmpty = scope.evaluateAsString(macro).isEmpty

            guard isAssigned || !isEmpty else {
                return nil
            }

            return macro.propertyListValue(in: scope)
        }

        /// Updates the content to have the given Info.plist key macro's value, if such a value is actually set.
        /// This is necessary because some Info.plist settings are valid with an empty value assigned by the developer.
        func updateContentWithInfoPlistKeyMacroValue(_ content: inout [String: PropertyListItem], _ name: String) -> Void {
            if let value = valueForInfoPlistKeyMacro(name) {
                content[name] = value
            }
        }

        // Note that for flexibility, instead of rigidly assigning only some values for some platforms, we (mostly) rely on the templates to specify the right values for the platforms involved, and to leave values they don't care about unspecified.

        let generatedInfoPlistKeys: [String] = [
            // General

            "CFBundleDisplayName",
            "LSApplicationCategoryType",
            "NSHumanReadableCopyright",
            "NSPrincipalClass",
            "ITSAppUsesNonExemptEncryption",
            "ITSEncryptionExportComplianceCode",
            "NSLocationTemporaryUsageDescriptionDictionary",

            // macOS

            "LSBackgroundOnly",
            "LSUIElement",
            "NSMainNibFile",
            "NSMainStoryboardFile",

            // iOS and Derived

            "UILaunchStoryboardName",
            "UIMainStoryboardFile",
            "UIRequiredDeviceCapabilities",
            "UISupportedInterfaceOrientations",
            "UIUserInterfaceStyle",

            // iOS

            "LSSupportsOpeningDocumentsInPlace",
            "NSSensorKitPrivacyPolicyURL",
            "NSSupportsLiveActivities",
            "NSSupportsLiveActivitiesFrequentUpdates",
            "UIApplicationSupportsIndirectInputEvents",
            "UIRequiresFullScreen",
            "UIStatusBarHidden",
            "UIStatusBarStyle",
            "UISupportedInterfaceOrientations~ipad",
            "UISupportedInterfaceOrientations~iphone",
            "UISupportsDocumentBrowser",

            // watchOS

            "CLKComplicationPrincipalClass",
            "WKApplication",
            "WKCompanionAppBundleIdentifier",
            "WKExtensionDelegateClassName",
            "WKRunsIndependentlyOfCompanionApp",
            "WKWatchOnly",
            "WKSupportsLiveActivityLaunchAttributeTypes",

            // Metal

            "MetalCaptureEnabled",

            // Game Controller and Game Mode

            "GCSupportsControllerUserInteraction",
            "GCSupportsGameMode",

            // Sticker Packs

            "NSStickerSharingLevel",
        ] + usageDescriptionStringKeys

        for key in generatedInfoPlistKeys {
            updateContentWithInfoPlistKeyMacroValue(&content, key)
        }

        // General - Special Cases

        func updateContent(_ content: inout [String: PropertyListItem], key: String, buildSetting: String) -> Void {
            if let value = valueForInfoPlistKeyMacro(buildSetting, prefix: "") {
                content[key] = value
            }
        }

        // Only add the default keys if the corresponding build setting is defined, so that we don't overwrite static values for these keys which may be in the input Info.plist
        updateContent(&content, key: "CFBundleName", buildSetting: BuiltinMacros.PRODUCT_NAME.name)
        // <rdar://64456434> This should only be added if we will actually produce an executable
        updateContent(&content, key: "CFBundleExecutable", buildSetting: BuiltinMacros.EXECUTABLE_NAME.name)
        updateContent(&content, key: "CFBundleVersion", buildSetting: BuiltinMacros.CURRENT_PROJECT_VERSION.name)
        updateContent(&content, key: "CFBundleDevelopmentRegion", buildSetting: BuiltinMacros.DEVELOPMENT_LANGUAGE.name)
        updateContent(&content, key: "CFBundleIdentifier", buildSetting: BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER.name)
        updateContent(&content, key: "CFBundlePackageType", buildSetting: BuiltinMacros.PRODUCT_BUNDLE_PACKAGE_TYPE.name)
        updateContent(&content, key: "CFBundleShortVersionString", buildSetting: BuiltinMacros.MARKETING_VERSION.name)

        content["CFBundleInfoDictionaryVersion"] = .plString("6.0") // TODO: consider removing this since it likely isn't needed

        // iOS and Derived Platforms - Special Cases

        // This is one exception to the rule above about letting the templates specify values.
        if ["iOS", "tvOS"].contains(platform?.familyName ?? "") && productType is ApplicationProductTypeSpec {
            // According to rdar://47870882, watchOS should have this key as well, but for now
            // we'll avoid adding it for consistency with the new project templates in Xcode and to reduce the
            // risk that it breaks watchOS app installation on older versions of watchOS.
            content["LSRequiresIPhoneOS"] = .plBool(true)
        }

        // Allow iOS apps containing extensionless watchOS apps to be installed on iPads running versions of iPadOS affected by rdar://92164048
        if ["watchOS"].contains(platform?.familyName ?? "") && productType is ApplicationProductTypeSpec && productType?.conformsTo(identifier: "com.apple.product-type.application.watchapp2") == false {
            content["MinimumOSVersion~ipad"] = .plString("9.0")
        }

        if let launchScreenGenerationValue = valueForInfoPlistKeyMacro("UILaunchScreen_Generation") {
            if launchScreenGenerationValue == .plBool(true) {
                content["UILaunchScreen"] = .plDict(["UILaunchScreen": .plDict([:])])
            }
        }

        // iOS - Special Cases

        if let applicationSceneManifestGenerationValue = valueForInfoPlistKeyMacro("UIApplicationSceneManifest_Generation") {
            if applicationSceneManifestGenerationValue == .plBool(true) {
                // This used to just generate `{ UIApplicationSupportsMultipleScenes = YES; }`, but SwiftUI still needs a UISceneConfigurations key to be added too, even if its value is just an empty dictionary. See <rdar://101916343> and related.
                content["UIApplicationSceneManifest"] = .plDict([
                    "UIApplicationSupportsMultipleScenes": .plBool(true),
                    "UISceneConfigurations": .plDict([:]),
                ])
            }
        }

        // watchOS - Special Cases

        if platform?.familyName == "watchOS" && productType?.identifier == "com.apple.product-type.application.watchapp2" {
            content["WKWatchKitApp"] = .plBool(true)
        }

        return content
    }

    /// Add the keys from the `AdditionalInfo` dictionary in the platform to the Info.plist.  Only keys which do not exist in the input plist will be added.  This will modify the  input `plist` in place.
    private func addAdditionalEntriesFromPlatform(_ plist: inout PropertyListItem, context: InfoPlistProcessorTaskActionContext, outputDelegate: any TaskOutputDelegate) -> CommandResult
    {
        // If we were passed a platform with -platform, then we use its additional info.
        if platformName != nil
        {
            // Only do anything if the platform's additional info is not empty.
            if context.platform?.additionalInfoPlistEntries.count > 0
            {
                guard case .plDict(let dict) = plist else { outputDelegate.emitError("Info.plist contents are not a dictionary prior to adding additional entries from platform"); return .failed }
                var plistDict = dict

                // Go through the additional entries from the platform and add them to the plist dictionary.  But only if they're not already present in the plist.
                for (key, plValue) in context.platform?.additionalInfoPlistEntries ?? [:] where plistDict[key] == nil
                {
                    if case .plString(let value) = plValue
                    {
                        // In the past, the <some string> convention was used to indicate that the value for this key should be the value in the platform's properties.  It looks like no platform circa Xcode 9.0 uses this convention anymore, so we no longer support it and we warn if we find such a key - we should encourage platforms to use actual build setting evaluation instead.
                        if value.hasPrefix("<")  &&  value.hasSuffix(">")  &&  value.count > 2
                        {
                            outputDelegate.emitWarning("key '\(key)' in 'AdditionalInfo' dictionary for platform \(context.platform?.displayName ?? "") uses unsupported bracket evaluation convention for its value '\(value)'")
                            plistDict[key] = plValue
                        }
                        else
                        {
                            // String values which aren't surrounded by <>.
                            plistDict[key] = plValue
                        }
                    }
                    else
                    {
                        // Non-string values.
                        plistDict[key] = plValue
                    }
                }

                // Create a new PropertyListItem to send back out.
                plist = .plDict(plistDict)
            }
        }
        return .succeeded
    }

    /// Add the properties from the additional content file to the plist.  This will modify the plist in place.
    private func addAdditionalContent(from path: Path, _ plist: inout PropertyListItem, context: InfoPlistProcessorTaskActionContext, _ executionDelegate: any TaskExecutionDelegate, _ outputDelegate: any TaskOutputDelegate) -> CommandResult {
        // Read the additional content file and parse it as a property list.
        let contentsData: ByteString
        do {
            contentsData = try executionDelegate.fs.read(path)
        }
        catch {
            outputDelegate.emitError("unable to read additional content file '\(path.str)': \(error.localizedDescription)")
            return .failed
        }
        let additionalPlist: PropertyListItem
        do {
            (additionalPlist, _) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
        }
        catch let error as NSError {
            outputDelegate.emitError("unable to read property list from additional content file: \(path.str): \(error.localizedDescription)")
            return .failed
        }
        catch {
            outputDelegate.emitError("unable to read property list from additional content file: \(path.str): unknown error")
            return .failed
        }
        guard case .plDict(let additionalDict) = additionalPlist else {
            outputDelegate.emitError("additional content file is not a dictionary: \(path.str)")
            return .failed
        }

        // Extract the top-level dictionary from the main plist in a variable we can modify.
        guard case .plDict(var plistDict) = plist else {
            outputDelegate.emitError("Info.plist contents are not a dictionary prior to adding entries from additional content files")
            return .failed
        }

        // Go through the entries in the additional content dict and add them to the plist dictionary.  Note that we do *not* do a deep merge of dictionaries within the top-level dictionary.
        for (key, valueToMerge) in additionalDict {
            let workingValue = plistDict[key]

            // Handle special-case keys first.
            if key == "UIRequiredDeviceCapabilities" {
                if let mergedCapabilitiesResult = mergeUIRequiredDeviceCapabilities(valueToMerge, from: path, into: workingValue, from: inputPath!, outputDelegate) {
                    plistDict[key] = mergedCapabilitiesResult
                }
                else {
                    return .failed
                }
            } else if (key == "CFBundleIcons" || key.hasPrefix("CFBundleIcons~")) && context.scope.evaluate(BuiltinMacros.INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE) {
                plistDict[key] = mergeCFBundleIcons(valueToMerge: valueToMerge, into: workingValue)
            }
            // Merge other keys in a standard manner.
            else {
                if let workingValue = workingValue {
                    // If we already have a value for this key, then we perform a merge based on its type.
                    switch (workingValue, valueToMerge) {
                    case (let workingValue, let valueToMerge) where workingValue.isScalarType && valueToMerge.isScalarType:
                        // When both values are scalar types, we overwrite with the new value.
                        plistDict[key] = valueToMerge

                    case (.plArray(let workingArray), .plArray(let arrayToMerge)):
                        // Both values are arrays - we append the contents of the new value to the old value, making sure not to add the same value twice.
                        // (This would be easier if PropertyListItem were hashable and we could create an OrderedSet here.)
                        var newArray = workingArray
                        for item in arrayToMerge {
                            if !workingArray.contains(item) {
                                newArray.append(item)
                            }
                        }
                        plistDict[key] = .plArray(newArray)

                    case (.plDict(var workingDict), .plDict(let dictToMerge)):
                        // Both values are dictionaries - we merge the contents of the new value into the old value.  Note that we don't do a recursive merge, so if the same key appears in both, then we will overwrite it regardless of their respective types.
                        workingDict.addContents(of: dictToMerge)
                        plistDict[key] = .plDict(workingDict)

                    default:
                        // The two values are of different types, or types we don't recognize - this is an error.
                        outputDelegate.emitError("tried to merge \(valueToMerge.typeDisplayString) value for key '\(key)' onto \(workingValue.typeDisplayString) value")
                        return .failed
                    }
                }
                else {
                    // If the key isn't defined, then we can just set it.
                    plistDict[key] = valueToMerge
                }
            }
        }

        // Create a new PropertyListItem to send back out.
        plist = .plDict(plistDict)

        return .succeeded
    }

    private func addAppPrivacyContent(from path: Path, _ plist: inout PropertyListItem, _ executionDelegate: any TaskExecutionDelegate, _ outputDelegate: any TaskOutputDelegate) -> CommandResult {
        let trackedDomainsKey = "NSPrivacyTrackingDomains"

        // Read the privacy content file and parse it as a property list.
        let contentsData: ByteString
        do {
            contentsData = try executionDelegate.fs.read(path)
        }
        catch {
            outputDelegate.emitError("unable to read privacy file '\(path.str)': \(error.localizedDescription)")
            return .failed
        }
        let privacyPlist: PropertyListItem
        do {
            (privacyPlist, _) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
        }
        catch let error as NSError {
            outputDelegate.emitError("unable to read property list from privacy file: \(path.str): \(error.localizedDescription)")
            return .failed
        }
        catch {
            outputDelegate.emitError("unable to read property list from privacy file: \(path.str): unknown error")
            return .failed
        }
        guard case .plDict(let privacyDict) = privacyPlist else {
            outputDelegate.emitError("privacy file is not a dictionary: \(path.str)")
            return .failed
        }

        // Extract the top-level dictionary from the main plist in a variable we can modify.
        guard case .plDict(var plistDict) = plist else {
            outputDelegate.emitError("Info.plist contents are not a dictionary prior to adding entries from additional content files")
            return .failed
        }

        var trackedDomains = plistDict[trackedDomainsKey]?.arrayValue ?? []
        if let additionalTrackedDomains = privacyDict[trackedDomainsKey]?.arrayValue {
            // It's import to both remove duplicates and sort the items to ensure stable file contents.
            var set = Set<String>(trackedDomains.compactMap( { $0.stringValue }))
            for domain in additionalTrackedDomains.compactMap( { $0.stringValue }) {
                set.insert(domain)
            }
            trackedDomains = set.sorted().map { PropertyListItem.plString($0) }
        }
        if !trackedDomains.isEmpty {
            plistDict[trackedDomainsKey] = .plArray(trackedDomains)

            // Create a new PropertyListItem to send back out.
            plist = .plDict(plistDict)

            return .succeeded
        }

        return .succeeded
    }

    private func mergeUIDeviceFamilyContent(into plistDict: inout [String: PropertyListItem], context: InfoPlistProcessorTaskActionContext, _ executionDelegate: any TaskExecutionDelegate, _ outputDelegate: any TaskOutputDelegate) -> PropertyListItem {
        // If we're targeting a specific device family, set that into the Info.plist.
        let targetedDeviceFamily = context.scope.evaluate(BuiltinMacros.TARGETED_DEVICE_FAMILY)
        let isMacCatalyst = context.sdkVariant?.isMacCatalyst == true
        if !targetedDeviceFamily.isEmpty || isMacCatalyst, let sdkVariant = context.sdkVariant {
            let (devices, effectiveDevices, _, unexpectedValues) = sdkVariant.evaluateTargetedDeviceFamilyBuildSetting(context.scope, context.productType)

            for string in unexpectedValues {
                outputDelegate.emitWarning("unexpected TARGETED_DEVICE_FAMILY item: `\(string)`")
            }

            if !effectiveDevices.isEmpty {
                // If no devices were specified, but this platform has device families, warn
                if devices.isEmpty {
                    let allowed = sdkVariant.deviceFamilies.targetDeviceIdentifiers.sorted()
                    if !allowed.isEmpty {
                        let platformDisplayName: String
                        if isMacCatalyst {
                            platformDisplayName = BuildVersion.Platform.macCatalyst.displayName(infoLookup: executionDelegate.infoLookup)
                        } else {
                            platformDisplayName = context.platform?.familyDisplayName ?? ""
                        }

                        let targetedDeviceFamilyValueString = !targetedDeviceFamily.isEmpty ? " (\(targetedDeviceFamily))" : ""

                        let title = "TARGETED_DEVICE_FAMILY value\(targetedDeviceFamilyValueString) does not contain any device family values compatible with the \(platformDisplayName) platform"
                        if allowed.count == 1 {
                            let suffix = !isMacCatalyst ? " to indicate that this target supports the '\(sdkVariant.deviceFamilies.deviceDisplayName(for: allowed[0]) ?? "<<unknown>>")' device family" : ""
                            outputDelegate.emitWarning("\(title). Please add the value '\(allowed[0])' to the TARGETED_DEVICE_FAMILY build setting\(suffix).")
                        } else {
                            outputDelegate.emitWarning("\(title). Please add one or more of the following values to the TARGETED_DEVICE_FAMILY build setting to indicate the device families supported by this target: \(allowed.map { "'\($0)' (indicating '\(sdkVariant.deviceFamilies.deviceDisplayName(for: $0) ?? "<<unknown>>")')" }.joined(separator: ", ")).")
                        }
                    }
                }

                // Generate the UIDeviceFamily key.
                if plistDict["UIDeviceFamily"] != nil {
                    outputDelegate.emitWarning("User supplied UIDeviceFamily key in the Info.plist will be overwritten. Please use the build setting TARGETED_DEVICE_FAMILY and remove UIDeviceFamily from your Info.plist.")
                }
                plistDict["UIDeviceFamily"] = .plArray(effectiveDevices.sorted().map{ .plInt($0) })
            }
        }

        return .plDict(plistDict)
    }

    /// Remove or add entries based on the platform being built for.  This is primarily interesting for macCatalyst, since an iOS target contains keys not relevant (and even harmful) on macOS, and may be changed to contain macOS keys which should not be included when building for iOS.
    private func editPlatformSpecificEntries(in plistDict: inout [String: PropertyListItem], _ outputDelegate: any TaskOutputDelegate, context: InfoPlistProcessorTaskActionContext) -> PropertyListItem {
        let isMacCatalyst = context.sdkVariant?.isMacCatalyst == true

        /// Convenience enum used to define whether an Info.plist key is supported or not supported on certain platform families.
        enum PlatformFamilySupportInfo {
            /// Indicates that this key is supported on these platform families and no others.
            case supportedOnlyOn(Set<String>)
            /// Indicates that this key is supported on all platform families except these.
            case notSupportedOn(Set<String>)
        }

        /// Utility function to remove a key for a platform, and emit output about the change if it is defined.
        func remove(unsupportedKey key: String, _ reason: String) {
            if plistDict[key] != nil {
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: "removing entry for \"\(key)\" - \(reason)\n"))
                plistDict.removeValue(forKey: key)
            }
        }

        /// Utility function to remove a value from a key for a platform, and emit output about the change if it is defined.
        func remove(unsupportedValue value: String, from key: String, _ reason: String) {
            if let itemListValue = plistDict[key]?.arrayValue {
                var itemList = itemListValue
                let num = itemList.removeAll(where: { $0.stringValue == value })
                if num > 0 {
                    outputDelegate.emitOutput(ByteString(encodingAsUTF8: "removing value \"\(value)\" for \"\(key)\" - \(reason)\n"))
                }
                plistDict[key] = PropertyListItem.plArray(itemList)
            }
        }

        /// Mapping of all keys known to not be supported on some platforms to the info about which platforms they are or aren't supported on.
        let keyPlatformSupport: [String: PlatformFamilySupportInfo] = [
            // Keys not supported on macOS, watchOS.
            "LSRequiresIPhoneOS":               .notSupportedOn(Set(["macOS", "watchOS"])),

            // Keys only supported on macOS.
            "LSBackgroundOnly":                 .supportedOnlyOn(Set(["macOS"])),
            "LSUIElement":                      .supportedOnlyOn(Set(["macOS"])),
            "NSDocumentClass":                  .supportedOnlyOn(Set(["macOS"])),
            "NSServices":                       .supportedOnlyOn(Set(["macOS"])),
            "NSSupportsAutomaticTermination":   .supportedOnlyOn(Set(["macOS"])),
            "NSSupportsSuddenTermination":      .supportedOnlyOn(Set(["macOS"])),

            // Keys only supported on macOS, iOS, tvOS.
            "LSApplicationCategoryType":        .supportedOnlyOn(Set(["macOS", "iOS", "tvOS"])),
        ]

        /// Mapping of all the values for keys known to not be supported on some platforms to the info about which platforms they are or aren't supported on.
        let keyValuesPlatformSupport: [String:[String:PlatformFamilySupportInfo]] = [
            "UIBackgroundModes": [
                "audio": .supportedOnlyOn(["iOS", "tvOS", "watchOS", "xrOS"]),
                "location": .supportedOnlyOn(["iOS", "watchOS"]),
                "voip": .supportedOnlyOn(["iOS", "watchOS", "xrOS"]),
                "fetch": .supportedOnlyOn(["iOS", "tvOS", "xrOS"]),
                "remote-notification": .supportedOnlyOn(["iOS", "tvOS", "watchOS", "xrOS"]),
                "newsstand-content": .supportedOnlyOn(["iOS"]),
                "external-accessory": .supportedOnlyOn(["iOS"]),
                "bluetooth-central": .supportedOnlyOn(["iOS", "watchOS", "xrOS"]),
                "bluetooth-peripheral": .supportedOnlyOn(["iOS"]),
                "network-authentication": .supportedOnlyOn(["iOS", "xrOS"]),
                "processing": .supportedOnlyOn(["iOS", "tvOS", "xrOS"]),
                "push-to-talk": .supportedOnlyOn(["iOS"]),
                "nearby-interaction": .supportedOnlyOn(["iOS"]),
            ]
        ]

        // Process all the keys we might need to remove.  We process them in a sorted order to ensure any output to the transcript is deterministic.
        for (key, platformInfo) in keyPlatformSupport.sorted(byKey: <) {
            switch platformInfo {
            case .notSupportedOn(let platforms):
                // If the platform we're building for is not supported for this key, then remove it.
                if platforms.contains(context.platform?.familyName ?? "") {
                    remove(unsupportedKey: key, "not supported on \(context.platform?.familyDisplayName ?? "")")
                }
            case .supportedOnlyOn(let platforms):
                // If this key is only supported for some platforms, and the platform we're building for is not among them, then remove it.
                if !platforms.contains(context.platform?.familyName ?? "") {
                    let reason: String
                    if let platform = platforms.only {
                        reason = "only supported on \(platform)"
                    }
                    else {
                        reason = "not supported on \(context.platform?.familyDisplayName ?? "")"
                    }
                    remove(unsupportedKey: key,  reason)
                }
            }
        }

        // Process all the keys we might need to remove.  We process them in a sorted order to ensure any output to the transcript is deterministic.
        for (key, valueDict) in keyValuesPlatformSupport.sorted(byKey: <) {
            for (value, platformInfo) in valueDict.sorted(byKey: <) {
                switch platformInfo {
                case .notSupportedOn(let platforms):
                    if platforms.contains(context.platform?.familyName ?? "") {
                        remove(unsupportedValue: value, from: key, "not supported on \(context.platform?.familyDisplayName ?? "")")
                    }

                case .supportedOnlyOn(let platforms):
                    // Let either iOS key-values through for Mac Catalyst...
                    // rdar://96613340 (Change strings to enum values and separate macCatalyst from iOS/macOS)
                    if isMacCatalyst && platforms.contains("iOS") { continue }

                    if !platforms.contains(context.platform?.familyName ?? "") {
                        let reason: String
                        if let platform = platforms.only {
                            reason = "only supported on \(platform)"
                        }
                        else {
                            reason = "not supported on \(context.platform?.familyDisplayName ?? "")"
                        }
                        remove(unsupportedValue: value, from: key,  reason)
                    }
                }
            }
        }

        /// Utility function to add an entry to the Info.plist, and emit output about the change.
        func set(_ key: String, to value: PropertyListItem, displayString: String? = nil) {
            let displayString = displayString ?? "\(value.unsafePropertyList)"
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: "adding entry for \"\(key)\" => \(displayString)\n"))
            plistDict[key] = value
        }

        // Add macCatalyst-specific entries.
        if isMacCatalyst {
            // Default NSSupportsAutomaticTermination and NSSupportsSuddenTermination to YES for macCatalyst if it is not defined.  But only for app targets.
            if context.productType is ApplicationProductTypeSpec {
                if plistDict["NSSupportsAutomaticTermination"] == nil {
                    set("NSSupportsAutomaticTermination", to: .plBool(true))
                }
                if plistDict["NSSupportsSuddenTermination"] == nil {
                    set("NSSupportsSuddenTermination", to: .plBool(true))
                }
            }
        }

        return .plDict(plistDict)
    }

    /// Recursively merge subdictionaries for `CFBundleIcons` to avoid clobbering values that aren't actually being set in `valueToMerge`.
    private func mergeCFBundleIcons(valueToMerge: PropertyListItem, into workingValue: PropertyListItem?) -> PropertyListItem {
        switch (valueToMerge, workingValue) {
        case (.plDict(let dictToMerge), .plDict(var workingDict)):
            for (key, valueToMerge) in dictToMerge {
                workingDict[key] = mergeCFBundleIcons(valueToMerge: valueToMerge, into: workingDict[key])
            }
            return .plDict(workingDict)
        default:
            return valueToMerge
        }
    }

    /// Special handling of the 'UIRequiredDeviceCapabilities' entry in an additional content file.  This entry can be either an array or a dictionary (or it might not exist at all), so we need to handle the case where the values from two different inputs are in different formats.
    private func mergeUIRequiredDeviceCapabilities(_ newValue: PropertyListItem, from newValuePath: Path, into oldValue: PropertyListItem?, from oldValuePath: Path, _ outputDelegate: any TaskOutputDelegate) -> PropertyListItem? {
        if let oldValue {
            switch (oldValue, newValue) {
            case (.plArray(let oldArray), .plArray(let newArray)):
                        // Both values are arrays - we append the contents of newValue to oldValue, making sure not to add the same value twice.
                // (This would be easier if PropertyListItem were hashable and we could create an OrderedSet here.)
                var resultArray = oldArray
                for item in newArray {
                    if !oldArray.contains(item) {
                        resultArray.append(item)
                    }
                }
                return .plArray(resultArray)

            // If one is an array or one is a dictionary, or both are dictionaries, then we promote any arrays to dictionaries and then merge them.  We do a shallow merge.
            case (.plArray(let oldArray), .plDict(let newDict)):
                var oldDict = [String: PropertyListItem]()
                for item in oldArray {
                    if let key = item.stringValue {
                        oldDict[key] = .plBool(true)
                    }
                    else {
                        outputDelegate.emitError("all values in 'UIRequiredDeviceCapabilities' must be strings (file \(oldValuePath)")
                        return nil
                    }
                }
                oldDict.addContents(of: newDict)
                return .plDict(oldDict)

            case (.plDict(var oldDict), .plArray(let newArray)):
                var newDict = [String: PropertyListItem]()
                for item in newArray {
                    if let key = item.stringValue {
                        newDict[key] = .plBool(true)
                    }
                    else {
                        outputDelegate.emitError("all values in 'UIRequiredDeviceCapabilities' must be strings (file \(newValuePath)")
                        return nil
                    }
                }
                oldDict.addContents(of: newDict)
                return .plDict(oldDict)

            case (.plDict(var oldDict), .plDict(let newDict)):
                oldDict.addContents(of: newDict)
                return .plDict(oldDict)

            default:
                // Emit an error that one or both values are not arrays or dictionaries.
                if oldValue.arrayValue == nil, oldValue.dictValue == nil {
                    outputDelegate.emitError("'UIRequiredDeviceCapabilities' must be an array or dictionary but it is \(oldValue.typeDisplayString.withIndefiniteArticle) (file \(oldValuePath.str)")
                }
                if newValue.arrayValue == nil, newValue.dictValue == nil {
                    outputDelegate.emitError("'UIRequiredDeviceCapabilities' must be an array or dictionary but it is \(newValue.typeDisplayString.withIndefiniteArticle) (file \(newValuePath.str)")
                }
                return nil
            }
        }
        else {
            // If oldValue is empty then we can just set it to newValue, as long as it is an array or a dictionary.
            if newValue.arrayValue != nil || newValue.dictValue != nil {
                return newValue
            }
            else {
                outputDelegate.emitError("'UIRequiredDeviceCapabilities' must be an array or dictionary but it is \(newValue.typeDisplayString.withIndefiniteArticle) (file \(oldValuePath.str))")
                return nil
            }
        }
    }

    private func setRequiredDeviceCapabilities(_ plist: inout PropertyListItem, context: InfoPlistProcessorTaskActionContext, outputDelegate: any TaskOutputDelegate) -> CommandResult
    {
        guard case .plDict(var plistDict) = plist else {
            outputDelegate.emitError("Info.plist contents are not a dictionary prior to setting required device capabilities")
            return .failed
        }

        var requiredDeviceCapabilities: PropertyListItem = requiredArchitecture.map { .plArray([.plString($0)]) } ?? .plArray([])

        let allArchitectures = context.cleanupRequiredArchitectures

        if let capabilities = plistDict["UIRequiredDeviceCapabilities"] {
            switch capabilities {
            case .plArray(let existingArchitectures):
                var workingArray = existingArchitectures

                if let requiredArchitecture {
                    let item: PropertyListItem = .plString(requiredArchitecture)
                    if !existingArchitectures.contains(item) {
                        workingArray.append(item)
                    }
                }

                workingArray = workingArray.filter { plistItem in
                    if case .plString(let arch) = plistItem {
                        return !allArchitectures.contains(arch) || (requiredArchitecture == arch)
                    }
                    return true
                }

                requiredDeviceCapabilities = .plArray(workingArray)
            case .plDict(let existingArchitectures):
                var workingDict = existingArchitectures

                if let requiredArchitecture {
                    workingDict[requiredArchitecture] = .plBool(true)
                }

                for architecture in allArchitectures {
                    if requiredArchitecture != architecture {
                        workingDict.removeValue(forKey: architecture)
                    }
                }

                requiredDeviceCapabilities = .plDict(workingDict)
            default:
                outputDelegate.emitError("'UIRequiredDeviceCapabilities' must be an array or dictionary but it is \(capabilities.typeDisplayString.withIndefiniteArticle)")
                return .failed
            }
        }

        plistDict["UIRequiredDeviceCapabilities"] = requiredDeviceCapabilities
        plist = .plDict(plistDict)

        return .succeeded
    }

    /// Validate the contents of the plist and emit warnings and errors as necessary.
    ///
    /// This method will perform some simple edits as part of validation, but more complicated edits (e.g., of more than a top-level value) should be broken out into a separate method.
    private func validatePlistContents(_ plistDict: inout [String: PropertyListItem], _ buildPlatform: BuildVersion.Platform?, _ buildPlatforms: Set<BuildVersion.Platform>?, _ deploymentTarget: Version?, _ scope: MacroEvaluationScope, infoLookup: any PlatformInfoLookup, context: InfoPlistProcessorTaskActionContext, outputDelegate: any TaskOutputDelegate) -> Bool {
        // Validate the bundle identifier.
        if let identifier = plistDict["CFBundleIdentifier"] {
            if case .plString(let identifierString) = identifier {
                if !identifierString.isEmpty {
                    if identifierString != identifierString.asLegalBundleIdentifier {
                        outputDelegate.emitWarning("invalid character in Bundle Identifier. This string must be a uniform type identifier (UTI) that contains only alphanumeric (A-Z,a-z,0-9), hyphen (-), and period (.) characters.")
                    }

                    let buildSettingIdentifierString = scope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER)
                    if identifierString != buildSettingIdentifierString {
                        outputDelegate.warning("User-supplied CFBundleIdentifier value '\(identifierString)' in the Info.plist must be the same as the PRODUCT_BUNDLE_IDENTIFIER build setting value '\(buildSettingIdentifierString)'.", location: .buildSetting(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER))
                    }
                }
            }
            else {
                outputDelegate.emitWarning("the value for Bundle Identifier must be of type string, but is \(identifier.typeDisplayString.withIndefiniteArticle)")
            }
        }

        // Figure out the minimum system version to use based on the SDK.
        let minimumSystemVersionKey: String
        switch buildPlatform {
        case .macOS?, .macCatalyst?:
            minimumSystemVersionKey = "LSMinimumSystemVersion"
        case .driverKit?:
            minimumSystemVersionKey = "OSMinimumDriverKitVersion"
        default:
            minimumSystemVersionKey = "MinimumOSVersion"
        }

        // Validate that the minimum system version key is not less than the deployment target.  If it is, then emit a warning and also set it to the deployment target.
        // Note that for MacCatalyst the relevant deployment target here is the macOS one.
        if let deploymentTarget, let minimumSystemVersionStr = plistDict[minimumSystemVersionKey]?.stringValue {
            let deploymentTargetName = scope.evaluate(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME)
            if minimumSystemVersionStr.isEmpty {
                outputDelegate.emitWarning("\(minimumSystemVersionKey) is explicitly set to empty - setting to value of \(deploymentTargetName) '\(deploymentTarget.description)'.")
                plistDict[minimumSystemVersionKey] = .plString(deploymentTarget.description)
            }
            else if let minimumSystemVersion = try? Version(minimumSystemVersionStr) {
                if minimumSystemVersion < deploymentTarget {
                    outputDelegate.emitWarning("\(minimumSystemVersionKey) of '\(minimumSystemVersionStr)' is less than the value of \(deploymentTargetName) '\(deploymentTarget.description)' - setting to '\(deploymentTarget.description)'.")
                    plistDict[minimumSystemVersionKey] = .plString(deploymentTarget.description)
                }
            }
            else {
                outputDelegate.emitError("\(minimumSystemVersionKey) '\(minimumSystemVersionStr)' is not a valid version.")
                return false
            }
        }

        if let productType = context.productType {
            if productType.conformsTo(identifier: "com.apple.product-type.application.on-demand-install-capable") {
                let appClipProhibitedKeys = ["CFBundleDocumentTypes", "LSApplicationQueriesSchemes"]
                for key in appClipProhibitedKeys {
                    if plistDict[key] != nil {
                        outputDelegate.emitWarning("'\(key)' has no effect for \(productType.name) targets and will be ignored.")
                    }
                }
            }
        }

        struct DeprecationInfo {
            enum DeprecationPlatform: String {
                case macOS
                case iOS
                case tvOS
                case watchOS
            }

            /// The values of the key that are deprecated, if only specific values are deprecated. `nil` indicates the key as a whole is deprecated.
            let values: [PropertyListItem]?

            /// An infix to display in the "use (alternative) instead" portion of the deprecation message.
            let alternate: String

            /// Mapping of platforms and the version of that platform beginning in which the deprecation warning should be shown.
            ///
            /// If the version is empty, the warning will always be shown for that platform.
            /// If there is no version value present for a platform at all, no warning will ever be shown for that platform.
            let deprecationVersions: [DeprecationPlatform: Version]

            init(values: [PropertyListItem]? = nil, alternate: String, deprecationVersions: [DeprecationPlatform: Version]) {
                self.values = values
                self.alternate = alternate
                self.deprecationVersions = deprecationVersions
            }
        }

        let plistKeyDeprecationInfo: [PropertyListKeyPath: DeprecationInfo] = [
            "UILaunchImages": .init(alternate: "launch storyboards", deprecationVersions: [.iOS: Version(), .tvOS: Version(13)]),
            "CLKComplicationSupportedFamilies": .init(alternate: "the ClockKit complications API", deprecationVersions: [.watchOS: Version(7)]),
            PropertyListKeyPath(.dict(.equal("NSAppTransportSecurity")), .dict(.equal("NSExceptionDomains")), .dict(.any), .any(.equal("NSExceptionMinimumTLSVersion"))): .init(values: [.plString("TLSv1.0"), .plString("TLSv1.1")], alternate: "TLSv1.2 or TLSv1.3", deprecationVersions: [
                .macOS: Version(12),
                .iOS: Version(15),
                .tvOS: Version(15),
                .watchOS: Version(8)
            ])
        ]

        for (key, info) in plistKeyDeprecationInfo.sorted(byKey: <) {
            for item in plistDict.propertyListItem[key] {
                if let platformFamily = DeprecationInfo.DeprecationPlatform(rawValue: context.platform?.familyName ?? ""), let deprecationVersion = info.deprecationVersions[platformFamily] {
                    if let specificValues = info.values, !specificValues.contains(item.value) {
                        continue
                    }

                    let prefixPart: String
                    if info.values != nil {
                        prefixPart = "The value \(item.value) for '\(item.actualKeyPath.joined(separator: "' => '"))'"
                    } else {
                        prefixPart = "'\(item.actualKeyPath.joined(separator: "' => '"))'"
                    }

                    let message: String
                    if deprecationVersion > Version() {
                        message = "\(prefixPart) has been deprecated starting in \(context.platform?.familyDisplayName ?? "") \(deprecationVersion.canonicalDeploymentTargetForm.description), use \(info.alternate) instead."
                    } else {
                        message = "\(prefixPart) has been deprecated, use \(info.alternate) instead."
                    }

                    if let deploymentTarget = deploymentTarget, deploymentTarget >= deprecationVersion {
                        outputDelegate.emitWarning(message)
                    }
                }
            }
        }

        validateUsageStringDefinitions(plistDict, outputDelegate: outputDelegate)
        return true
    }

    private func validateUsageStringDefinitions(_ plistDict: [String: PropertyListItem], outputDelegate: any TaskOutputDelegate) {
        let usageStringPlistEntries = plistDict.filter { key, _ in
            usageDescriptionStringKeys.contains(key)
        }

        for (key, value) in usageStringPlistEntries {
            switch value {
            case .plString(let stringValue):
                if stringValue.isEmpty {
                    outputDelegate.emitWarning("The value for \(key) must be a non-empty string.")
                }
            default:
                outputDelegate.emitWarning("The value for \(key) must be of type string, but is \(value.typeDisplayString.withIndefiniteArticle).")
            }
        }
    }

    /// Scans the path for an `PrivacyInfo.xcprivacy` file and returns the `Path` to that file, if found. Otherwise, returns `nil`.
    private func scanForPrivacyFile(at path: Path, fs: any FSProxy) -> Path? {
        do {
            return try fs.traverse(path) { $0.basename == "PrivacyInfo.xcprivacy" ? $0 : nil }.first
        }
        catch {}

        return nil
    }

    private func generatePackageInfo(atPath pkgInfoPath: Path, usingPlist plistDict: [String: PropertyListItem], context: InfoPlistProcessorTaskActionContext, _ executionDelegate: any TaskExecutionDelegate, _ outputDelegate: any TaskOutputDelegate) throws {
        // Get the Mac OS Roman four character code for a key.
        func getFourCharCode(forKey key: String) -> Data {
            guard let value = plistDict[key] else {
                return Data("????".utf8)
            }

            guard case let .plString(string) = value else {
                outputDelegate.emitWarning("key '\(key)' in 'Info.plist' is not a valid string value")
                return Data("????".utf8)
            }

            let evaluatedString = context.scope.evaluate(context.scope.table.namespace.parseString(string))
            guard let encoded = evaluatedString.data(using: .macOSRoman), encoded.count == 4 else {
                outputDelegate.emitWarning("value '\(evaluatedString)' for '\(key)' in 'Info.plist' must be a four character string")
                return Data("????".utf8)
            }

            return encoded
        }

        // Get the package type code and signature (a.k.a. creator) code from the Info.plist.  We do various correctness checks.  One of the more interesting restrictions is that both the type code and the signature code have to be convertible to Mac OS Roman encoding.  The reason for this is that both four-character codes are really OSTypes, which were implicitly encoded in Mac OS Roman back in historical times.
        let pkgInfoBytes = (OutputByteStream()
            <<< getFourCharCode(forKey: "CFBundlePackageType")
            <<< getFourCharCode(forKey: "CFBundleSignature")).bytes
        do {
            _ = try executionDelegate.fs.writeIfChanged(pkgInfoPath, contents: pkgInfoBytes)
        } catch {
            outputDelegate.emitError("unable to write file '\(pkgInfoPath.str)': \(error.localizedDescription)")
        }
    }


    // Serialization


    public override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(contextPath)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    public required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        self.contextPath = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}


private extension PropertyListItem
{
    /// Specialized private method to transform a property list by removing any keys which are in the set `keys` from any dictionary in the plist where the value for that key is empty.
    func byElidingRecursivelyEmptyStringValuesInDictionaries(_ keysToElide: Set<String>) -> PropertyListItem
    {
        switch self
        {
        case .plArray(let value):
            // Dive into the array to elide keys from any dictionaries in it.
            return .plArray(value.map({ return $0.byElidingRecursivelyEmptyStringValuesInDictionaries(keysToElide) }))

        case .plDict(let value):
            // Handle this dictionary.
            var result = [String: PropertyListItem]()
            for (key, item) in value
            {
                switch item
                {
                case .plString(let value):
                    // For strings, we elide it only if the key is in keysToElide and the value is empty.
                    if !value.isEmpty || !keysToElide.contains(key)
                    {
                        result[key] = item
                    }

                default:
                    // For other values we process them recursively.
                    result[key] = item.byElidingRecursivelyEmptyStringValuesInDictionaries(keysToElide)
                }
            }
            return .plDict(result)

        default:
            // For non-collection types we just return the item.
            return self
        }
    }
}

extension ProductTypeSpec {
    /// watchOS stub apps deployed to versions of watchOS earlier than 6.0 have a fixed set of Info.plist keys which are allowed.
    ///
    /// We need to be careful not to add any keys outside that list when deploying to legacy versions of watchOS.
    func requiresStrictInfoPlistKeys(_ scope: MacroEvaluationScope) -> Bool {
        guard let deploymentTarget = try? Version(scope.evaluate(BuiltinMacros.WATCHOS_DEPLOYMENT_TARGET)) else {
            return false
        }
        return identifier == "com.apple.product-type.application.watchapp2" && deploymentTarget < Version(6)
    }
}

extension PropertyListItem {
    var extensionPointIdentifier: String? {
        let foundationExtensionPointIdentifier = dictValue?["NSExtension"]?.dictValue?["NSExtensionPointIdentifier"]?.stringValue
        let extensionKitExtensionPointIdentifier = dictValue?["EXAppExtensionAttributes"]?.dictValue?["EXExtensionPointIdentifier"]?.stringValue
        switch (foundationExtensionPointIdentifier, extensionKitExtensionPointIdentifier) {
        case (let .some(id1), let .some(id2)):
            return Set([id1, id2]).only
        case (let .some(extensionPointIdentifier), nil), (nil, let .some(extensionPointIdentifier)):
            return extensionPointIdentifier
        case (nil, nil):
            return nil
        }
    }
}
