//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025-2026 Apple Inc. and the Swift project authors
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
        let useTripleIndexedSlices = cbc.scope.evaluate(BuiltinMacros.USE_TRIPLE_INDEXED_SLICES)
        let useClangDriver = useTripleIndexedSlices

        let linkerPath: Path
        let PRELINK_TOOL = cbc.scope.evaluate(BuiltinMacros.PRELINK_TOOL)
        if !PRELINK_TOOL.isEmpty {
            linkerPath = Path(PRELINK_TOOL)
        }
        else {
            if useClangDriver {
                guard let toolSpecInfo = await cbc.producer.clangSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredClangToolSpecInfo else {
                    delegate.error("Could not find path to clang binary to use to generate prelink object file")
                    return
                }
                linkerPath = toolSpecInfo.toolPath
            }
            else {
                guard let toolSpecInfo = await cbc.producer.ldLinkerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredLdLinkerToolSpecInfo else {
                    delegate.error("Could not find path to ld binary to use to generate prelink object file")
                    return
                }
                linkerPath = toolSpecInfo.toolPath
            }
        }

        let outputPath = cbc.output

        var extraInputs = [Path]()

        var commandLine = [linkerPath.str]
        commandLine.append("-r")
        if useTripleIndexedSlices {
            let tripleString = cbc.scope.evaluate(BuiltinMacros.CURRENT_TARGET_TRIPLE)
            commandLine += ["-target", tripleString]
        }
        else {
            let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
            commandLine += ["-arch", arch]
        }

        let cohortArchs = cbc.scope.evaluate(BuiltinMacros.COHORT_ARCHS)
        if !cohortArchs.isEmpty {
            commandLine += cohortArchs.flatMap { ["-arch-variant", $0] }
        }

        // Pass the platform number, deployment target, and version of the SDK being used to the linker, only if invoking ld directly. (clang will compute these values and pass them implicitly.)
        // This handles some scenarios where the linker can't determine the platform from the inputs (e.g., if all of the inputs are static libraries). rdar://154346861
        // If using triple-indexed slices then clang will pass the full target triple to the linker, and the linker can get the platform from that.
        if !useTripleIndexedSlices, let sdk = cbc.producer.sdk, let sdkVersion = sdk.version {
            for buildPlatform in cbc.producer.targetBuildVersionPlatforms(in: cbc.scope)?.sorted() ?? [] {
                let platformInfo = cbc.producer.lookupPlatformInfo(platform: buildPlatform)
                let minDeploymentTarget: String
                if let deploymentTargetSettingName = platformInfo?.deploymentTargetSettingName {
                    guard let value = cbc.scope.evaluate(cbc.scope.namespace.parseString("$(\(deploymentTargetSettingName))")).nilIfEmpty else {
                        continue
                    }
                    minDeploymentTarget = value
                } else if let defaultDeploymentTarget = platformInfo?.defaultDeploymentTarget ?? cbc.producer.sdkVariant?.defaultDeploymentTarget {
                    // SDKs which don't support availability or back deployment have no deployment target setting, so fall back to the default deployment target instead.
                    minDeploymentTarget = defaultDeploymentTarget.canonicalDeploymentTargetForm.description
                } else {
                    fatalError("Mach-O based platforms must provide a deployment target setting name or a default deployment target")
                }

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

        let sysroot = cbc.scope.evaluate(BuiltinMacros.SDK_DIR)
        if !sysroot.isEmpty {
            commandLine += [(useClangDriver ? "-isysroot" : "-syslibroot"), sysroot]
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

        let prelinkLibs = cbc.scope.evaluate(BuiltinMacros.PRELINK_LIBS)

        let dependencyInfoFile = cbc.scope.evaluate(BuiltinMacros.PRELINK_DEPENDENCY_INFO_FILE)
        if !dependencyInfoFile.isEmpty {
            commandLine += prelinkLibs
        } else {
            // Library options like -lfoo can't be tracked
            for lib in prelinkLibs {
                if !lib.isEmpty {
                    if lib.hasPrefix("-l") {
                        commandLine.append(lib)
                    } else {
                        let node = delegate.createNode(Path(lib))
                        commandLine.append(node.path.str)
                        extraInputs.append(node.path)
                    }
                }
            }
        }

        commandLine += ["-o", outputPath.str]

        var dependencyInfo: DependencyDataStyle?
        var outputs: [Path] = [outputPath]
        if !dependencyInfoFile.isEmpty {
            commandLine += ["-Xlinker", "-dependency_info", "-Xlinker", dependencyInfoFile.str]
            dependencyInfo = .dependencyInfo(dependencyInfoFile)
            outputs.append(dependencyInfoFile)
        }

        // Remove argument quoting (-Xlinker) if we're not using clang to drive the linker.
        // This is the simplest approach to allow targets which might be built using both drivers to specify options in PRELINK_FLAGS and other settings.
        if !useClangDriver {
            commandLine = commandLine.compactMap({ $0 == "-Xlinker" ? nil : $0 })
        }

        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)
        let slice = cbc.scope.evaluate(BuiltinMacros.CURRENT_SLICE_UNVERSIONED)
        let ruleInfo = ["PrelinkedObjectLink", outputPath.str, variant, slice]
        delegate.createTask(type: self, dependencyData: dependencyInfo, ruleInfo: ruleInfo, commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }) + extraInputs, outputs: outputs, action: nil, execDescription: "Link \(outputPath.basename)", enableSandboxing: enableSandboxing)
    }
}
