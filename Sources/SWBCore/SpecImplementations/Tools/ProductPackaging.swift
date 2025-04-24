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
import SWBMacro
import Foundation

public final class ProductPackagingToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.product-pkg-utility"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    fileprivate static let sandboxAndHardenedRuntimeBooleanEntitlements = [
        BuiltinMacros.RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES: "com.apple.security.cs.allow-dyld-environment-variables",
        BuiltinMacros.RUNTIME_EXCEPTION_ALLOW_JIT: "com.apple.security.cs.allow-jit",
        BuiltinMacros.RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY: "com.apple.security.cs.allow-unsigned-executable-memory",
        BuiltinMacros.RUNTIME_EXCEPTION_DEBUGGING_TOOL: "com.apple.security.cs.debugger",
        BuiltinMacros.RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION: "com.apple.security.cs.disable-executable-page-protection",
        BuiltinMacros.RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION: "com.apple.security.cs.disable-library-validation",
        BuiltinMacros.ENABLE_APP_SANDBOX: "com.apple.security.app-sandbox",
        BuiltinMacros.ENABLE_INCOMING_NETWORK_CONNECTIONS: "com.apple.security.network.server",
        BuiltinMacros.ENABLE_OUTGOING_NETWORK_CONNECTIONS: "com.apple.security.network.client",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_AUDIO_INPUT: "com.apple.security.device.audio-input",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_BLUETOOTH: "com.apple.security.device.bluetooth",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_CALENDARS: "com.apple.security.personal-information.calendars",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_CAMERA: "com.apple.security.device.camera",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_CONTACTS: "com.apple.security.personal-information.addressbook",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_LOCATION: "com.apple.security.personal-information.location",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY: "com.apple.security.personal-information.photos-library",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_PRINTING: "com.apple.security.print",
        BuiltinMacros.ENABLE_RESOURCE_ACCESS_USB: "com.apple.security.device.usb",
        BuiltinMacros.AUTOMATION_APPLE_EVENTS: "com.apple.security.automation.apple-events",
    ]

    fileprivate static let sandboxFileAccessSettingsAndEntitlements: [(EnumMacroDeclaration<FileAccessMode>, String)] = [
        (BuiltinMacros.ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER, "com.apple.security.files.downloads"),
        (BuiltinMacros.ENABLE_FILE_ACCESS_PICTURE_FOLDER, "com.apple.security.assets.pictures"),
        (BuiltinMacros.ENABLE_FILE_ACCESS_MUSIC_FOLDER, "com.apple.security.assets.music"),
        (BuiltinMacros.ENABLE_FILE_ACCESS_MOVIES_FOLDER, "com.apple.security.assets.movies"),
        (BuiltinMacros.ENABLE_USER_SELECTED_FILES, "com.apple.security.files.user-selected"),
    ]

    /// Construct a task to create the entitlements (`.xcent`) file.
    /// - parameter cbc: The command build context.  This includes the input file to process (until <rdar://problem/29117572> is fixed), and the output file in the product to which write the contents.
    /// - parameter delegate: The task generation delegate.
    public func constructProductEntitlementsTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ entitlementsVariant: EntitlementsVariant, fs: any FSProxy) async {
        // Only generate the entitlements file when building.
        guard cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

        // Don't generate the entitlements file unless we have a valid expanded identity.
        guard !cbc.scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY).isEmpty else { return }

        // If we don't have provisioning inputs then we bail out.
        guard let provisioningTaskInputs = cbc.producer.signingSettings?.inputs else { return }

        if let productType = cbc.producer.productType {
            let (warnings, errors) = productType.validate(provisioning: provisioningTaskInputs)
            for warning in warnings {
                delegate.warning(warning)
            }
            for error in errors {
                delegate.error(error)
            }
        }

        let codeSignEntitlementsInput: FileToBuild? = {
            if let entitlementsPath = cbc.scope.evaluate(BuiltinMacros.CODE_SIGN_ENTITLEMENTS).nilIfEmpty {
                return FileToBuild(absolutePath: delegate.createNode(entitlementsPath).path, inferringTypeUsing: cbc.producer)
            }
            return nil
        }()

        var inputs: [FileToBuild] = [codeSignEntitlementsInput].compactMap { $0 }
        let outputPath = cbc.output

        // Create a lookup closure to for overriding build settings.
        let lookup: ((MacroDeclaration) -> MacroExpression?) = {
            macro in
            switch macro {
            case BuiltinMacros.OutputPath:
                return cbc.scope.namespace.parseLiteralString(outputPath.str) as MacroStringExpression
            case BuiltinMacros.CodeSignEntitlements:
                return Static { cbc.scope.namespace.parseLiteralString("YES") } as MacroStringExpression
            case BuiltinMacros.OutputFormat:
                return Static { cbc.scope.namespace.parseLiteralString("xml") } as MacroStringExpression
            default:
                return nil
            }
        }

        // Compute the command line. We do this before adding the fake input file to the inputs array.
        let commandLine = await commandLineFromTemplate(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: inputs, output: outputPath), delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)

        // It seems like all of these modifications to the entitlements file should really be in ProcessProductEntitlementsTaskAction, as that would make it a bit clearer to the user that Swift Build is making changes to what we got from the entitlements subsystem, and would make this more testable (in ProcessProductEntitlementsTaskActionTests).
        // This functionality is tested in CodeSignTaskConstructionTests.testEntitlementsDictionaryProcessing().
        var entitlements = provisioningTaskInputs.entitlements(for: entitlementsVariant)
        if !entitlements.isEmpty {
            if var entitlementsDictionary = entitlements.dictValue {
                if cbc.scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING), !cbc.scope.evaluate(BuiltinMacros.ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW) {
                    // For deployment builds, strip com.apple.security.get-task-allow to disallow debugging and produce a binary that can be notarized.
                    // <rdar://problem/44952574> DevID+: Adjust injection of com.apple.security.get-task-allow for archives
                    entitlementsDictionary["com.apple.security.get-task-allow"] = nil
                }

                // rdar://142845111 (Turn on `AppSandboxConflictingValuesEmitsWarning` by default)
                if SWBFeatureFlag.enableAppSandboxConflictingValuesEmitsWarning.value {
                    EntitlementConflictDiagnosticEmitter.checkForConflicts(cbc, delegate, entitlementsDictionary: entitlementsDictionary, entitlementsPath: codeSignEntitlementsInput?.absolutePath)
                }

                if cbc.producer.platform?.signingContext.supportsAppSandboxAndHardenedRuntime() == true {
                    // Inject entitlements that are settable via build settings.
                    // This is only supported when App Sandbox or Hardened Runtime is enabled.
                    for (buildSetting, entitlementPrefix) in Self.sandboxFileAccessSettingsAndEntitlements {
                        let fileAccessValue = cbc.scope.evaluate(buildSetting)
                        switch fileAccessValue {
                        case .readOnly:
                            entitlementsDictionary["\(entitlementPrefix).read-only"] = .plBool(true)
                        case .readWrite:
                            entitlementsDictionary["\(entitlementPrefix).read-write"] = .plBool(true)
                        case .none:
                            break
                        }
                    }

                    for (buildSetting, entitlement) in Self.sandboxAndHardenedRuntimeBooleanEntitlements {
                        if cbc.scope.evaluate(buildSetting) {
                            entitlementsDictionary[entitlement] = .plBool(true)
                        }
                    }
                }

                entitlements = PropertyListItem(entitlementsDictionary)
            }

            // FIXME: <rdar://problem/29117572> Right now we need to create a fake auxiliary file to use as the input if we're using the entitlements from the provisioning task inputs.  Once in-process tasks have signatures, we should use those here instead, and the task and inputs below should be removed.
            do {
                guard let bytes = try? entitlements.asBytes(.xml) else {
                    delegate.error("error: could not write entitlements source file")
                    return
                }
                cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: cbc.input.absolutePath), delegate, contents: ByteString(bytes), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                inputs.append(cbc.input)
            }
        }

        // The entitlements used should be emitted as part of the tool output.
        let additionalOutput = [
            "Entitlements:",
            "",
            "\(entitlements.unsafePropertyList)",
        ]

        // ProcessProductEntitlementsTaskAction expects a non-empty destination platform name.
        guard let platform = cbc.producer.platform else {
            delegate.error("error: no platform to build for")
            return
        }

        // Create the task action, and then the task.
        let action = delegate.taskActionCreationDelegate.createProcessProductEntitlementsTaskAction(scope: cbc.scope, mergedEntitlements: entitlements, entitlementsVariant: entitlementsVariant, destinationPlatformName: platform.name, entitlementsFilePath: codeSignEntitlementsInput?.absolutePath, fs: fs)

        delegate.createTask(type: self, ruleInfo: ["ProcessProductPackaging", codeSignEntitlementsInput?.absolutePath.str ?? "", outputPath.str], commandLine: commandLine, additionalOutput: additionalOutput, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs.map(\.absolutePath), outputs: [ outputPath ], action: action, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }

    /// Construct a task to create the provisioning file (commonly named `embedded.mobileprovision`).
    public func constructProductProvisioningProfileTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.input
        let outputPath = cbc.output

        let inputPath = input.absolutePath

        // Create a lookup closure to force $(OutputFormat) to 'none'.
        let lookup: ((MacroDeclaration) -> MacroExpression?) = {
            macro in
            switch macro {
            case BuiltinMacros.OutputPath:
                return cbc.scope.namespace.parseLiteralString(outputPath.str) as MacroStringExpression
            case BuiltinMacros.OutputFormat:
                return Static { cbc.scope.namespace.parseLiteralString("none") } as MacroStringExpression
            default:
                return nil
            }
        }

        // Compute the command line.
        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)

        let action = delegate.taskActionCreationDelegate.createProcessProductProvisioningProfileTaskAction()
        delegate.createTask(type: self, ruleInfo: ["ProcessProductPackaging", inputPath.str, outputPath.str], commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: [ outputPath ], action: action, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)

        // FIXME: Need to add this signature info to the command once commands support signatures.  (I think we probably only need to add the UUID.)
//        producer.extraSignatureInfo = inputs.profileUUID ?: inputs.profilePath.pathString;
    }
}

private extension ProductPackagingToolSpec {
    enum EntitlementConflictDiagnosticEmitter {
        private static func validate(entitlement: String, withExpectedValue expectedValue: Bool, entitlementsDictionary: [String: PropertyListItem], entitlementsPath: Path?, buildSettingName: String, buildSettingValue: String, delegate: some TaskGenerationDelegate) {
            switch entitlementsDictionary[entitlement] {
            case let .plBool(entitlementValue):
                if expectedValue != entitlementValue {
                    let message: String
                    let childDiagnostics: [Diagnostic]

                    let entitlementsLocation: Diagnostic.Location
                    if let entitlementsPath {
                        entitlementsLocation = .path(entitlementsPath)
                    } else {
                        entitlementsLocation = .unknown
                    }

                    if expectedValue {
                        // This is when build setting is true and entitlement is false
                        message = "The '\(buildSettingName)' build setting is set to '\(buildSettingValue)', but entitlement '\(entitlement)' is set to '\(entitlementValue ? "YES" : "NO")' in your entitlements file."
                        childDiagnostics = [
                            .init(behavior: .note, location: entitlementsLocation, data: .init("To enable '\(buildSettingName)', remove the entitlement from your entitlements file.")),
                            .init(behavior: .note, location: .buildSettings(names: [buildSettingName]), data: .init("To disable '\(buildSettingName)', remove the entitlement from your entitlements file and disable '\(buildSettingName)' in  build settings."))
                        ]
                    } else {
                        message = "The '\(buildSettingName)' build setting is set to '\(buildSettingValue)', but entitlement '\(entitlement)' is set to '\(entitlementValue ? "YES" : "NO")' in your entitlements file."
                        childDiagnostics = [
                            .init(behavior: .note, location: .buildSettings(names: [buildSettingName]), data: .init("To enable '\(buildSettingName)', remove the entitlement from your entitlements file, and enable '\(buildSettingName)' in build settings.")),
                            .init(behavior: .note, location: entitlementsLocation, data: .init("To disable '\(buildSettingName)', remove the entitlement from your entitlements file."))
                        ]
                    }

                    delegate.warning(message, childDiagnostics: childDiagnostics)
                }
            default:
                break
            }
        }

        static func checkForConflicts(_ cbc: CommandBuildContext, _ delegate: some TaskGenerationDelegate, entitlementsDictionary: [String: PropertyListItem], entitlementsPath: Path?) {
            for (buildSetting, entitlementPrefix) in sandboxFileAccessSettingsAndEntitlements {
                let fileAccessValue = cbc.scope.evaluate(buildSetting)
                let buildSettingName = buildSetting.name

                let readOnlyEntitlement = "\(entitlementPrefix).read-only"
                let readWriteEntitlement = "\(entitlementPrefix).read-write"

                switch fileAccessValue {
                case .readOnly:
                    validate(entitlement: readOnlyEntitlement, withExpectedValue: true, entitlementsDictionary: entitlementsDictionary, entitlementsPath: entitlementsPath, buildSettingName: buildSettingName, buildSettingValue: "readOnly", delegate: delegate)

                case .readWrite:
                    validate(entitlement: readWriteEntitlement, withExpectedValue: true, entitlementsDictionary: entitlementsDictionary, entitlementsPath: entitlementsPath, buildSettingName: buildSettingName, buildSettingValue: "readWrite", delegate: delegate)
                case .none:
                    validate(entitlement: readOnlyEntitlement, withExpectedValue: false, entitlementsDictionary: entitlementsDictionary, entitlementsPath: entitlementsPath, buildSettingName: buildSettingName, buildSettingValue: "None", delegate: delegate)
                    validate(entitlement: readWriteEntitlement, withExpectedValue: false, entitlementsDictionary: entitlementsDictionary, entitlementsPath: entitlementsPath, buildSettingName: buildSettingName, buildSettingValue: "None", delegate: delegate)

                }
            }

            for (buildSetting, entitlement) in ProductPackagingToolSpec.sandboxAndHardenedRuntimeBooleanEntitlements {
                let buildSettingValue = cbc.scope.evaluate(buildSetting)
                let buildSettingName = buildSetting.name

                validate(entitlement: entitlement, withExpectedValue: buildSettingValue, entitlementsDictionary: entitlementsDictionary, entitlementsPath: entitlementsPath, buildSettingName: buildSettingName, buildSettingValue: "\(buildSettingValue ? "YES" : "NO")", delegate: delegate)
            }
        }
    }
}
