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
public import SWBMacro
import Foundation

public final class CodesignToolSpec : CommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.codesign"

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        var codesign = Path(cbc.scope.evaluate(BuiltinMacros.CODESIGN))
        if codesign.isEmpty {
            codesign = Path("/usr/bin/codesign")
        }
        if !codesign.isAbsolute {
            codesign = resolveExecutablePath(cbc, codesign)
        }
        return codesign.str
    }

    /// Construct the task to sign a file.
    /// - parameter cbc: The command build context.  This includes as its output the file to run codesign on.
    /// - parameter delegate: The task generation delegate.
    /// - parameter productToSign: The path to the product to sign.  This will often be the same as the output in the command build context, but it will sometimes be different (e.g., for a framework on macOS, the product is the `.framework` wrapper, but the output is the `Versions/A` file in that wrapper).  The product name is used for the name of the entitlements file, if any.
    /// - parameter bundleFormat: The format of the bundle, if known.  Callers should pass a value here if they know for sure the format of the bundle being signed.
    /// - parameter isProducingBinary: `true` if this target is expected to be producing a binary that would need to be signed. Usually true unless there are no sources in a bundle.
    /// - parameter fileToSignMayBeWrapper: `true` if the file being signed might be a wrapper.  Callers can pass `false` here if they know for sure that the file being signed is not a wrapper (i.e., it's a standalone file) to circumvent this method's effort to determine the files codesign will generate inside the wrapper.  Callers should pass `true` here if they're not absolutely sure of the nature of the file being signed.
    /// - parameter isReSignTask: `true` if this task is intended to re-sign a copied file.
    /// - parameter isAdditionalSignTask: `true` if this task is one of multiple signing tasks of this same path in this same build.  For example, test targets using TEST_HOST will re-sign the app they're being embedded in, after the app has already been built.
    /// - parameter ignoreEntitlements: `true` if this task should not use add entitlements.
    /// - parameter extraInputs: The list of extra inputs the code signing tasks should depend on. Ideally, this should be merged into CommandBuildContext's input property.
    public func constructCodesignTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, productToSign: Path, bundleFormat: BundleFormat? = nil, isProducingBinary: Bool = true, fileToSignMayBeWrapper: Bool = true, isReSignTask: Bool = false, isAdditionalSignTask: Bool = false, ignoreEntitlements: Bool = false, extraInputs: [Path] = []) {

        guard let provisioningTaskInputs = cbc.producer.signingSettings?.inputs else { return }

        // Don't code sign unless we have a valid expanded identity.
        let expandedCodeSignIdentity = cbc.scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY)
        if expandedCodeSignIdentity.isEmpty {
            if cbc.scope.evaluate(BuiltinMacros.CODE_SIGNING_ALLOWED)  &&  cbc.scope.evaluate(BuiltinMacros.CODE_SIGNING_REQUIRED) {
                let productTypeString = { () -> String in
                    guard let productType = cbc.producer.productType else { return "" }
                    return " for product type '\(productType.name)"
                }()

                let sdkString = { () -> String in
                    guard let sdk = cbc.producer.sdk else { return "" }
                    return " in \(sdk.displayName)"
                }()

                delegate.error("Code signing is required\(productTypeString)\(sdkString).")
            }
            return
        }

        let fileToSign = cbc.input
        let productToSign = productToSign.normalize()
        let outputPath = fileToSign.absolutePath
        var extraInputs = extraInputs

        // NOTE: The build settings in the xcspec file are not used to generate the command line - everything is done in code below.

        var commandLine = [computeExecutablePath(cbc)]

        commandLine += ["--force", "--sign", expandedCodeSignIdentity]

        let codeSignKeychain = cbc.scope.evaluate(BuiltinMacros.CODE_SIGN_KEYCHAIN)
        if !codeSignKeychain.isEmpty {
            commandLine += ["--keychain", codeSignKeychain]
        }

        // Add the other flags.  Warn the user about illegal flags.
        var generateDesignatedRequirements = true

        // In a deployment build, use codesign's default timestamp behavior unless --timestamp was passed in OTHER_CODE_SIGN_FLAGS.
        // In a debug build, explicitly disable timestamp unless --timestamp was passed.
        var addTimestampNoneFlag = !cbc.scope.evaluate(BuiltinMacros.DEPLOYMENT_POSTPROCESSING)
        var illegalFlags = [String]()
        for flag in cbc.scope.evaluate(BuiltinMacros.OTHER_CODE_SIGN_FLAGS) {
            if flag.hasPrefix("-d")  ||  flag == "--display"  ||  flag == "-h" {
                illegalFlags.append(flag)
            }
            else {
                commandLine.append(flag)
            }

            if flag.hasPrefix("-r")  ||  flag.hasPrefix("--requirements") {
                generateDesignatedRequirements = false
            }

            if flag.hasPrefix("--timestamp") {
                addTimestampNoneFlag = false
            }
        }

        if !illegalFlags.isEmpty {
            let illegalFlagsString = illegalFlags.joined(separator: ",")
            delegate.warning("CodeSign warning: invalid codesign flags '\(illegalFlagsString)'; ignoring...")
        }

        let knownOptionFlags: [String: BooleanMacroDeclaration] = [
            "library": BuiltinMacros.ENABLE_LIBRARY_VALIDATION,
            "restrict": BuiltinMacros.CODE_SIGN_RESTRICT,
            "runtime": BuiltinMacros.ENABLE_HARDENED_RUNTIME,
        ]

        func supportsCodeSignOption(_ option: String) -> Bool {
            // The 'runtime' option to enable the hardened runtime is not supported by simulators.
            cbc.producer.platform?.isSimulator != true || option != "runtime"
        }

        let additionalOptions = knownOptionFlags.sorted(byKey: <).compactMap { flag, buildSetting in cbc.scope.evaluate(buildSetting) ? flag : nil }.filter(supportsCodeSignOption)

        if let optionsIndex = commandLine.firstIndex(of: "-o") ?? commandLine.firstIndex(of: "--options"), optionsIndex + 1 < commandLine.count {
            let optionString = commandLine[optionsIndex + 1]
            var options = OrderedSet(optionString.split(separator: ",").map(String.init))
            if cbc.scope.evaluate(BuiltinMacros.DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS) {
                for (flag, buildSetting) in knownOptionFlags.sorted(byKey: <) {
                    if let index = options.firstIndex(of: flag) {
                        options.remove(at: index)
                        delegate.warning("The '\(flag)' codesign option flag must be set using the \(buildSetting.name) build setting, not via \(BuiltinMacros.OTHER_CODE_SIGN_FLAGS.name). It will be ignored.", location: .buildSetting(buildSetting))
                    }
                }
            }
            options.append(contentsOf: additionalOptions)
            let combinedOptions = options.elements.filter(supportsCodeSignOption)
            if !combinedOptions.isEmpty {
                commandLine[optionsIndex + 1] = combinedOptions.sorted().joined(separator: ",")
            } else {
                commandLine.remove(at: optionsIndex + 1)
                commandLine.remove(at: optionsIndex)
            }
        } else if !additionalOptions.isEmpty {
            commandLine.append("-o")
            commandLine.append(additionalOptions.joined(separator: ","))
        }

        // Add entitlements if directed to, if not re-signing, and if we have some.
        if !ignoreEntitlements, !isReSignTask {
            if let entitlements = cbc.producer.signingSettings?.signedEntitlements {
                commandLine.append("--entitlements")
                commandLine.append(entitlements.output.str)
            }
        }

        // Add the entitlements file dependency by searching the command line, so that we pick it up regardless of whether we passed --entitlements here in the spec or it was passed via OTHER_CODE_SIGN_FLAGS.
        for entitlementsFilePath in commandLine.byExtractingElementsHavingPrefix("--entitlements") {
            extraInputs.append(Path(entitlementsFilePath))
        }

        // Add designated requirements if we need to.
        if generateDesignatedRequirements {
            if let unevaluatedDesignatedRequirements = provisioningTaskInputs.designatedRequirements {
                if let designatedRequirements = defaultDesignatedRequirements(cbc, commandLine, unevaluatedDesignatedRequirements) {
                    commandLine.append(contentsOf: ["--requirements", "=designated => \(designatedRequirements)"])
                }
            }
        }

        // Add the --timestamp=none option if appropriate.
        if addTimestampNoneFlag {
            commandLine.append("--timestamp=none")
        }

        // If we're re-signing, then add the option to preserve metadata.
        if isReSignTask {
            commandLine.append("--preserve-metadata=identifier,entitlements,flags")
        }

        // For increased kernel security hardening. This follows App Store behavior and works on all systems all the way up to Liberty
        commandLine.append("--generate-entitlement-der")

        if let processLaunchConstraint = cbc.producer.signingSettings?.launchConstraints.process {
            commandLine.append(contentsOf: ["--launch-constraint-self", processLaunchConstraint.str])
        }

        if let parentProcessLaunchConstraint = cbc.producer.signingSettings?.launchConstraints.parentProcess {
            commandLine.append(contentsOf: ["--launch-constraint-parent", parentProcessLaunchConstraint.str])
        }

        if let responsibleProcessLaunchConstraint = cbc.producer.signingSettings?.launchConstraints.responsibleProcess {
            commandLine.append(contentsOf: ["--launch-constraint-responsible", responsibleProcessLaunchConstraint.str])
        }

        if cbc.producer.systemInfo?.operatingSystemVersion >= Version(14) {
            if let libraryLoadConstraint = cbc.producer.signingSettings?.libraryConstraint {
                commandLine.append(contentsOf: ["--library-constraint", libraryLoadConstraint.str])
            }
        }

        // Add the path to the file to sign.
        commandLine.append(outputPath.str)

        // Get the environment to pass to the tool.
        var environment: [String: String] = environmentFromSpec(cbc, delegate).bindingsDictionary
        environment.merge(
            CodesignToolSpec.computeCodeSigningEnvironment(cbc, codesignAllocate: environment[BuiltinMacros.CODESIGN_ALLOCATE.name]),
            uniquingKeysWith: { (_, second) in second })

        // Normally, the additional inputs shouldn't be applied on a resign-task for the target as doing so can create a cycle between the Copy Files Phase and Run Script Phase. However, due to the way that app hosted tests work (e.g. misuse the copy phase to inject content into the app bundle), we need to provide a provision to track that in order to properly-resign the app bundle (cf: testIncrementalCodesignForCopyFileChangesWithAppHostedTests).
        // NOTE: This does mean that the users can actually introduce a cycle if they have a script phase that also injects content into the app bundle related to the test bundle that is getting copied in. However, this should be an obscure usage.
        // NOTE: This also means that we can tend to over-sign some of the additional test infrastructure libraries... not sure it's actually worth trying to filter those out and if we can do it reliably without over filtering.
        if !isReSignTask || !cbc.scope.evaluate(BuiltinMacros.TEST_HOST).isEmpty {
            extraInputs = (extraInputs + delegate.additionalCodeSignInputs).sorted()
        }

        // FIXME: We currently track the product to sign as an input, but this doesn't seem right given that the tool won't actually look at that?
        // NOTE: The use of `createDirectoryTreeNode()` is done as it may very well be the case that the input is a bundle (e.g. .xctest, .framework, .appex, etc...). This is safe to use on files as well.
        var inputs: [any PlannedNode] = [delegate.createNode(productToSign), delegate.createNode(outputPath)] + extraInputs.map{ delegate.createDirectoryTreeNode($0, excluding: []) } + cbc.commandOrderingInputs

        // Detect whether or not we are signing a bundle, so that we can properly report the inputs and outputs. This is important for our mutable node handling being able to connect the tasks properly.
        var outputs: [any PlannedNode]
        if fileToSignMayBeWrapper, isProducingBinary, !isAdditionalSignTask, ((isReSignTask && fileToSign.fileType.isBundle) || (!isReSignTask && cbc.producer.productType is BundleProductTypeSpec)) {
            let binaryPath: Path
            if isReSignTask {
                // We have to infer the binary path, which is something of a hack.  It also assumes the bundle we're signing *has* a binary.
                //
                // Note that the difference between use of `productToSign` and `outputPath` here is intentional, and is designed to accommodate the handling of macOS `Versions/A/<name>`.
                let bundleName = productToSign.basenameWithoutSuffix

                let format: BundleFormat
                if let bundleFormat = bundleFormat {
                    format = bundleFormat
                } else if fileToSign.fileType.isFramework {
                    format = .framework(version: nil)
                } else {
                    format = .bundle(shallow: cbc.scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE))
                }

                switch format {
                case .framework:
                    // For frameworks, we can always just append the bundle name, since on macOS we're signing the Versions/A folder.
                    binaryPath = outputPath.join(bundleName)
                case let .bundle(shallow):
                    // For non-framework bundles we need to include Contents/MacOS when not using shallow bundles.
                    if !shallow {
                        binaryPath = outputPath.join("Contents/MacOS").join(bundleName)
                    }
                    else {
                        binaryPath = outputPath.join(bundleName)
                    }
                }
            } else {
                binaryPath = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()
            }
            let binaryOutput = delegate.createNode(binaryPath)
            let signatureOutput = delegate.createNode(outputPath.join("_CodeSignature"))
            inputs.append(binaryOutput)
            outputs = [delegate.createNode(outputPath), binaryOutput, signatureOutput]
        } else {
            outputs = [delegate.createNode(outputPath)]
        }

        let expandedCodeSignIdentityName = cbc.scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY_NAME)
        var additionalOutput = ["Signing Identity:     \"\(expandedCodeSignIdentityName.isEmpty ? expandedCodeSignIdentity : expandedCodeSignIdentityName)\""]
        if let provisioningInputs = cbc.producer.signingSettings?.inputs, let profileName = provisioningInputs.profileName, let profileUUID = provisioningInputs.profileUUID {
            additionalOutput.append("Provisioning Profile: \"\(profileName)\"")
            additionalOutput.append("                      (\(profileUUID))")
        }

        // If we were passed any command ordering outputs, then we use them, otherwise we create one.
        let commandOrderingOutputs = (!cbc.commandOrderingOutputs.isEmpty ? cbc.commandOrderingOutputs : [delegate.createVirtualNode("CodeSign \(outputPath.str)")])
        outputs.append(contentsOf: commandOrderingOutputs)

        delegate.createTask(type: self, ruleInfo: ["CodeSign", outputPath.str], commandLine: commandLine, additionalOutput: additionalOutput, environment: EnvironmentBindings(environment), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, mustPrecede: [], action: delegate.taskActionCreationDelegate.createCodeSignTaskAction(), execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing, repairViaOwnershipAnalysis: false)
    }

    /// Returns the path to the codesign file for the given target. This is used as a contract between any task that needs to contribe to the invalidation of the signature (e.g. re-running the CodeSign task).
    public static func codesignDependencyFilePath(for target: ConfiguredTarget, scope: MacroEvaluationScope) -> Path {
        return Path(scope.evaluate(BuiltinMacros.OBJECT_FILE_DIR).str + "-" + scope.evaluate(BuiltinMacros.CURRENT_VARIANT)).join("\(scope.evaluate(BuiltinMacros.PRODUCT_NAME))-codesign.d")
    }

    private func defaultDesignatedRequirements(_ cbc: CommandBuildContext, _ commandLine: [String], _ unevaluatedDesignatedRequirements: String) -> String? {
        // Attempt to use the same identifier codesign will use.
        var identifier: String = "$self.identifier"

        // First, look for a -i or --identifier codesign parameter.
        if let identifierIdx = commandLine.firstIndex(of: "-i") ?? commandLine.firstIndex(of: "--identifier") {
            // If we found find a -i or --identifier parameter, use it as the identifier.
            if identifierIdx+1 < commandLine.count {
                identifier = commandLine[identifierIdx+1]
            }
        }

        // If there are no periods in the identifier, look for a --prefix codesign parameter and if found, prepend it to the identifier.
        if identifier.contains(".") {
            if let prefixIdx = commandLine.firstIndex(of: "--prefix") {
                if prefixIdx+1 < commandLine.count {
                    let prefix = commandLine[prefixIdx+1]
                    identifier = prefix + identifier
                }
            }
        }

        // Replace any backslashes with backslash-backslash:
        identifier = identifier.replacingOccurrences(of: "\\", with: "\\\\")
        // Replace any quotes with backslash-quote:
        identifier = identifier.replacingOccurrences(of: "\"", with: "\\\"")

        // Evaluate the designated requirements and return them.
        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.CODE_SIGN_IDENTIFIER:
                // If I understand the old code signing logic correctly, this will never have build setting references in it.
                return cbc.scope.namespace.parseLiteralString(identifier)
            default:
                return nil
            }
        }
        return cbc.scope.evaluate(cbc.scope.namespace.parseString(unevaluatedDesignatedRequirements), lookup: lookup)
    }


    /// Computes the environment for invoking the code signing tool.
    ///
    /// - Parameters:
    ///   - cbc: The command build context.
    ///   - codesignAllocate: Path to the codesign allocate tool. If present, this path will be used instead of evaluating the corresponding macro.
    /// - Returns: Key-value pair of the computed environment.
    static func computeCodeSigningEnvironment(
        _ cbc: CommandBuildContext,
        codesignAllocate: String? = nil
    ) -> [String: String] {
        // Use the path to the given codesign allocate tool or try to evaluate it.
        var codesignAllocate = Path(codesignAllocate ?? cbc.scope.evaluate(BuiltinMacros.CODESIGN_ALLOCATE))
        if codesignAllocate.isEmpty {
            codesignAllocate = Path("codesign_allocate")
        }
        if !codesignAllocate.isAbsolute {
            // FIXME: Should we report an error/warning if we can't find the tool?
            codesignAllocate = cbc.producer.executableSearchPaths.lookup(codesignAllocate) ?? codesignAllocate
        }
        return [BuiltinMacros.CODESIGN_ALLOCATE.name: codesignAllocate.str]
    }
}

public enum BundleFormat {
    case framework(version: String?)
    case bundle(shallow: Bool)
}
