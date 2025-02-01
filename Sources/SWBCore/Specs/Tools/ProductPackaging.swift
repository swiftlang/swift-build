//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
import SWBMacro

public final class ProductPackagingToolSpec : GenericCommandLineToolSpec, SpecIdentifierType {
    public static let identifier = "com.apple.tools.product-pkg-utility"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

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

                let isAppSandboxEnabled = cbc.scope.evaluate(BuiltinMacros.ENABLE_APP_SANDBOX)
                let isHardenedRuntimeEnabled = cbc.scope.evaluate(BuiltinMacros.ENABLE_HARDENED_RUNTIME)

                // rdar://142845111 (Turn on `AppSandboxConflictingValuesEmitsWarning` by default)
                if SWBFeatureFlag.enableAppSandboxConflictingValuesEmitsWarning {
                    EntitlementConflictDiagnosticEmitter.checkForConflicts(cbc, delegate, entitlementsDictionary: entitlementsDictionary)
                }

                if isAppSandboxEnabled || isHardenedRuntimeEnabled {
                    // Inject entitlements that are settable via build settings.
                    // This is only supported when App Sandbox or Hardened Runtime is enabled.
                    let fileAccessSettingsAndEntitlements: [(EnumMacroDeclaration<FileAccessMode>, String)] = [
                        (BuiltinMacros.ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER, "com.apple.security.files.downloads"),
                        (BuiltinMacros.ENABLE_FILE_ACCESS_PICTURE_FOLDER, "com.apple.security.assets.pictures"),
                        (BuiltinMacros.ENABLE_FILE_ACCESS_MUSIC_FOLDER, "com.apple.security.assets.music"),
                        (BuiltinMacros.ENABLE_FILE_ACCESS_MOVIES_FOLDER, "com.apple.security.assets.movies"),
                        (BuiltinMacros.ENABLE_USER_SELECTED_FILES, "com.apple.security.files.user-selected"),
                    ]

                    for (buildSettingSetting, entitlementPrefix) in fileAccessSettingsAndEntitlements {
                        let fileAccessValue = cbc.scope.evaluate(buildSettingSetting)
                        switch fileAccessValue {
                        case .readOnly:
                            entitlementsDictionary["\(entitlementPrefix).read-only"] = .plBool(true)
                        case .readWrite:
                            entitlementsDictionary["\(entitlementPrefix).read-write"] = .plBool(true)
                        case .none:
                            break
                        }
                    }

                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_APP_SANDBOX) {
                        entitlementsDictionary["com.apple.security.app-sandbox"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_INCOMING_NETWORK_CONNECTIONS) {
                        entitlementsDictionary["com.apple.security.network.server"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_OUTGOING_NETWORK_CONNECTIONS) {
                        entitlementsDictionary["com.apple.security.network.client"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_AUDIO_INPUT) {
                        entitlementsDictionary["com.apple.security.device.audio-input"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_BLUETOOTH) {
                        entitlementsDictionary["com.apple.security.device.bluetooth"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_CALENDARS) {
                        entitlementsDictionary["com.apple.security.personal-information.calendars"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_CAMERA) {
                        entitlementsDictionary["com.apple.security.device.camera"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_CONTACTS) {
                        entitlementsDictionary["com.apple.security.personal-information.addressbook"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_LOCATION) {
                        entitlementsDictionary["com.apple.security.personal-information.location"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY) {
                        entitlementsDictionary["com.apple.security.personal-information.photos-library"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_PRINTING) {
                        entitlementsDictionary["com.apple.security.print"] = .plBool(true)
                    }
                    if cbc.scope.evaluate(BuiltinMacros.ENABLE_RESOURCE_ACCESS_USB) {
                        entitlementsDictionary["com.apple.security.device.usb"] = .plBool(true)
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
        static func checkForConflicts(_ cbc: CommandBuildContext, _ delegate: some TaskGenerationDelegate, entitlementsDictionary: [String: PropertyListItem]) {

            let isAppSandboxEnabled = cbc.scope.evaluate(BuiltinMacros.ENABLE_APP_SANDBOX)

            switch entitlementsDictionary["com.apple.security.app-sandbox"] {
            case let .plBool(value):
                if isAppSandboxEnabled != value {
                    let appSandboxBuildSettingName = BuiltinMacros.ENABLE_APP_SANDBOX.name
                    let message: String
                    let childDiagnostics: [Diagnostic]

                    if isAppSandboxEnabled {
                        // This is when build setting is true and entitlement is false
                        message = "The \(appSandboxBuildSettingName) build setting is set to YES, but is set to NO in your entitlements file."
                        childDiagnostics = [
                            .init(behavior: .note, location: .unknown, data: .init("To enable App Sandbox, remove the entitlement from your entitlements file.")),
                            .init(behavior: .note, location: .unknown, data: .init("To disable App Sandbox, remove the entitlement from your entitlements file, and set the \(appSandboxBuildSettingName) build setting to NO."))
                        ]
                    } else {
                        message = "The \(appSandboxBuildSettingName) build setting is set to NO, but is set to YES in your entitlements file."
                        childDiagnostics = [
                            .init(behavior: .note, location: .unknown, data: .init("To enable App Sandbox, remove the entitlement from your entitlements file, and set the \(appSandboxBuildSettingName) build setting to YES.")),
                            .init(behavior: .note, location: .unknown, data: .init("To disable App Sandbox, remove the entitlement from your entitlements file."))
                        ]
                    }

                    delegate.warning(message, childDiagnostics: childDiagnostics)
                }
            default:
                break
            }
        }
    }
}
