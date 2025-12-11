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

import SWBUtil
import SWBMacro

/// Spec to use the linker to run `ld -r` to create a prelinked object file.
public final class PrelinkedObjectLinkSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.prelinked-object-link"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return PrelinkedObjectLinkSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard let toolSpecInfo = await cbc.producer.ldLinkerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredLdLinkerToolSpecInfo else {
            delegate.error("Could not find path to ld binary")
            return
        }

        let outputPath = cbc.output

        let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        var extraInputs = [Path]()

        var commandLine = [toolSpecInfo.toolPath.str]
        commandLine += ["-r", "-arch", arch]

        if let sdk = cbc.producer.sdk, let sdkVersion = sdk.version {
            for buildPlatform in cbc.producer.targetBuildVersionPlatforms(in: cbc.scope)?.sorted() ?? [] {
                let deploymentTargetSettingName = buildPlatform.deploymentTargetSettingName(infoLookup: cbc.producer)
                if let minDeploymentTarget = cbc.scope.evaluate(cbc.scope.namespace.parseString("$(\(deploymentTargetSettingName)")).nilIfEmpty {
                    let version: Version
                    if cbc.scope.evaluate(BuiltinMacros.IS_ZIPPERED) && buildPlatform == .macCatalyst {
                        guard let correspondingVersion = sdk.versionMap["macOS_iOSMac"]?[sdkVersion] else {
                            delegate.error("'\(sdk.canonicalName)' is missing a Mac Catalyst version mapping for '\(sdkVersion)'")
                            continue
                        }
                        version = correspondingVersion
                    } else {
                        version = sdkVersion
                    }
                    commandLine += ["-platform_version", "\(buildPlatform.rawValue)", minDeploymentTarget, version.canonicalDeploymentTargetForm.description]
                }
            }
        }

        // We do not pass the deployment target to the linker here.  Instead the linker infers the platform and deployment target from the .o files being collected.  We did briefly pass it to the linker to silence a linker warning - if we ever see issues here we should confer with the linker folks to make sure we do the right thing.  See <rdar://problem/51800525> for more about the history here.

        let sysroot = cbc.scope.evaluate(BuiltinMacros.SDK_DIR)
        if !sysroot.isEmpty {
            commandLine += ["-syslibroot", sysroot]
        }

        commandLine += cbc.producer.ldLinkerSpec.sparseSDKSearchPathArguments(cbc)

        if cbc.scope.evaluate(BuiltinMacros.KEEP_PRIVATE_EXTERNS) {
            commandLine.append("-keep_private_externs")
        }
        let exportedSymbolsFile = cbc.scope.evaluate(BuiltinMacros.EXPORTED_SYMBOLS_FILE)
        if !exportedSymbolsFile.isEmpty {
            let node = delegate.createNode(exportedSymbolsFile)
            commandLine += ["-exported_symbols_list", node.path.str]
            extraInputs.append(node.path)
        }
        let unexportedSymbolsFile = cbc.scope.evaluate(BuiltinMacros.UNEXPORTED_SYMBOLS_FILE)
        if !unexportedSymbolsFile.isEmpty {
            let node = delegate.createNode(unexportedSymbolsFile)
            commandLine += ["-unexported_symbols_list", node.path.str]
            extraInputs.append(node.path)
        }
        commandLine += cbc.scope.evaluate(BuiltinMacros.PRELINK_FLAGS)
        let warningLdFlags = cbc.scope.evaluate(BuiltinMacros.WARNING_LDFLAGS)
        if !warningLdFlags.isEmpty {
            // WARNING_LDFLAGS for some reason is only used for creating the prelinked object file.
            delegate.warning("WARNING_LDFLAGS is deprecated; use OTHER_LDFLAGS instead.", location: .buildSetting(BuiltinMacros.WARNING_LDFLAGS))
            commandLine += warningLdFlags
        }
        commandLine += cbc.inputs.map({ $0.absolutePath.str })
        commandLine += cbc.scope.evaluate(BuiltinMacros.PRELINK_LIBS)
        commandLine += ["-o", outputPath.str]

        delegate.createTask(type: self, ruleInfo: ["PrelinkedObjectLink", outputPath.str], commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: [outputPath], action: nil, execDescription: "Link \(outputPath.basename)", enableSandboxing: enableSandboxing)
    }
}
