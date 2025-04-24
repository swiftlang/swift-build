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

public enum ScriptType: Sendable {
    case externalTarget
    case shellScriptPhase
}

/// Construct the commandline for an external target (or legacy target in project model parlance).
///
/// - Parameters:
///   - target: The external target to use.
///   - action: The action to use.
///   - settings: The settings to use for computing the script's environment and search paths.
///   - workspaceContext: The workspace context to use for computing the script's environment.
///   - scope: The scope in which to expand build settings.
public func constructCommandLine(for target: ExternalTarget, action: String, settings: Settings, workspaceContext: WorkspaceContext, scope: MacroEvaluationScope) -> (executable: String, arguments: [String], workingDirectory: Path, environment: [String: String]) {
    let scope = settings.globalScope
    func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
        switch macro {
        case BuiltinMacros.ACTION where action == "build":
            // NOTE: This is cheating, we are swapping a string list for a string to get the expands-to-empty behavior. Currently this is allowed by the evaluation system.
            return scope.namespace.parseStringList("")
        case BuiltinMacros.ACTION where action != "build":
            return scope.namespace.parseString(action)
        default:
            return nil
        }
    }

    let buildTool = scope.evaluate(target.toolPath, lookup: lookup)
    let workingDirectory = (settings.project?.sourceRoot ?? workspaceContext.workspace.path.dirname).join(Path(scope.evaluate(target.workingDirectory, lookup: lookup)))
    var environment: [String: String] = [:]
    if target.passBuildSettingsInEnvironment {
        environment = computeScriptEnvironment(.externalTarget, scope: scope, settings: settings, workspaceContext: workspaceContext)
    }

    // Always set ACTION in the environment.
    //
    // FIXME: This needs to be set to "clean" when we are cleaning.
    environment["ACTION"] = action == "build" ? "" : action

    // Set the PATH environment variable to include all of the paths the build system itself uses.
    let existingPath = environment["PATH"] ?? ""
    environment["PATH"] = settings.executableSearchPaths.environmentRepresentation + existingPath

    if settings.fallbackFrameworkSearchPaths.paths.count > 0 {
        // Set the DYLD_FALLBACK_FRAMEWORK_PATH environment variable to include all of the toolchain frameworks
        let existingFrameworkPath = environment["DYLD_FALLBACK_FRAMEWORK_PATH"] ?? ""
        environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = settings.fallbackFrameworkSearchPaths.environmentRepresentation + existingFrameworkPath
    }

    if settings.fallbackLibrarySearchPaths.paths.count > 0 {
        // Set the DYLD_FALLBACK_LIBRARY_PATH environment variable to include all of the toolchain libraries
        let existingLibraryPath = environment["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = settings.fallbackLibrarySearchPaths.environmentRepresentation + existingLibraryPath
    }

    return (buildTool, scope.evaluate(target.arguments, lookup: lookup), workingDirectory, environment)
}

/// Compute the environment to use for executing a script in the given context.
///
/// - type: The type of shell script being executed.
/// - scope: The scope in which to expand build settings.
/// - settings: The settings to use for computing the environment.
/// - workspaceContext: The workspace context to use for computing the environment
public func computeScriptEnvironment(_ type: ScriptType, scope: MacroEvaluationScope, settings: Settings, workspaceContext: WorkspaceContext) -> [String: String] {
    var result = [String: String]()

    // FIXME: Note that we merged this function for shell scripts with the very similar code that was used to build the environment for external build commands. Currently in order to retain perfect compatibility we do various things conditionally based on the mode, but really this code should just be a single function that is used for both contexts at some point.

    // We supply a subset of the full PEC variables to shell scripts.
    //
    // FIXME: An ER in Xcode is to find some way to supply conditional build settings. We could do that reasonably by mangling them into the old form for any name we identify as should-be-passed-in-environment.

    // Evaluate all of the variable names to export, and put the non-empty ones in the environment.
    for macro in settings.exportedMacroNames {
        let value = scope.evaluateAsString(macro)
        if !value.isEmpty {
            result[macro.name] = value
        }
    }

    switch type {
    case .externalTarget:
        break
    case .shellScriptPhase:
        // Add the internal only settings, if appropriate.
        for macro in settings.exportedNativeMacroNames {
            let value = scope.evaluateAsString(macro)
            if !value.isEmpty {
                result[macro.name] = value
            }
        }

        // Add several custom settings (either renamed, with special processing, or always present even when empty).
        result["PRODUCT_SETTINGS_PATH"] = settings.infoPlistFilePath(scope, workspaceContext).str
        // FIXME: Is this used by anything?
        result["PKGINFO_FILE_PATH"] = scope.evaluate(BuiltinMacros.TEMP_DIR).join("PkgInfo").str

        // Export settings about sparse SDKs.
        if !settings.sparseSDKs.isEmpty {
            result["ADDITIONAL_SDK_DIRS"] = settings.sparseSDKs.map({ $0.path.str }).joined(separator: " ")
            for sparseSDK in settings.sparseSDKs {
                // Note that if multiple sparse SDKs in use have the same family identifier, then only one will 'win' over the others for the family identifier form.
                for directoryMacro in sparseSDK.directoryMacros {
                    result[directoryMacro.name] = sparseSDK.path.str
                }
            }
        }

        // Add the path.
        //
        // FIXME: Xcode adds this again later, so this might be effectively dead code.
        result["PATH"] = scope.evaluate(BuiltinMacros.PATH)
    }

    // Set more custom properties directly into the environment.
    let alwaysPresentStringMacros = [
        BuiltinMacros.ACTION,
        BuiltinMacros.PROJECT_NAME, BuiltinMacros.PRODUCT_NAME,
        BuiltinMacros.TARGET_NAME,
        BuiltinMacros.INSTALL_OWNER, BuiltinMacros.INSTALL_GROUP,
        BuiltinMacros.INSTALL_MODE_FLAG,
        BuiltinMacros.DEVELOPMENT_LANGUAGE,
        BuiltinMacros.FRAMEWORK_VERSION]
    for macro in alwaysPresentStringMacros {
        result[macro.name] = scope.evaluate(macro)
    }

    let alwaysPresentPathMacros = [
        BuiltinMacros.SRCROOT, BuiltinMacros.OBJROOT, BuiltinMacros.SYMROOT,
        BuiltinMacros.DSTROOT, BuiltinMacros.SDKROOT,
        BuiltinMacros.LOCROOT, BuiltinMacros.LOCSYMROOT,
        BuiltinMacros.INSTALL_DIR,
        BuiltinMacros.TEMP_FILE_DIR,
        BuiltinMacros.DERIVED_FILES_DIR,
        BuiltinMacros.TARGET_BUILD_DIR,
        BuiltinMacros.BUILT_PRODUCTS_DIR]
    for macro in alwaysPresentPathMacros {
        result[macro.name] = scope.evaluate(macro).str
    }
    
    for macro in [BuiltinMacros.BUILD_COMPONENTS, BuiltinMacros.BUILD_VARIANTS] {
        result[macro.name] = scope.evaluateAsString(macro)
    }

    // Override BUILD_STYLE, which has been deprecated.
    result["BUILD_STYLE"] = ""

    switch type {
    case .externalTarget:
        result["TEMP_FILES_DIR"] = scope.evaluate(BuiltinMacros.TEMP_FILES_DIR).str
    case .shellScriptPhase:
        // Add several per-variant or per-arch settings.
        for _ in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
            for _ in scope.evaluate(BuiltinMacros.ARCHS) {
                // FIXME: Implement, need names of per-variant-object-fir-dir-macros and per-variant link file list macros.
            }
        }

        result["TEMP_FILES_DIR"] = scope.evaluate(BuiltinMacros.TEMP_FILE_DIR).str

        // Add VERSIONING_STUB, if it would be live.
        //
        // FIXME: This is a total hack just for testing and compatibility. It
        // happened this way because Xcode4 would just set this in the PEC and
        // never remove it.
        //
        // FIXME: Implement or deprecate.

        // FIXME: This is a confusing interaction with the GCC_VERSION
        // manipulation done previously, resolve this.

        // Add the toolchains setting.
        // Construct a TOOLCHAINS setting in the environment.
        result["TOOLCHAINS"] = settings.toolchains.map({ $0.identifier }).joined(separator: " ")

        result["PATH"] = settings.executableSearchPaths.environmentRepresentation
        if settings.fallbackFrameworkSearchPaths.paths.count > 0 {
            result["DYLD_FALLBACK_FRAMEWORK_PATH"] = settings.fallbackFrameworkSearchPaths.environmentRepresentation
        }
        if settings.fallbackLibrarySearchPaths.paths.count > 0 {
            result["DYLD_FALLBACK_LIBRARY_PATH"] = settings.fallbackLibrarySearchPaths.environmentRepresentation
        }
    }

    result.removeValue(forKey: "EFFECTIVE_PLATFORM_SUFFIX")

    // Remove deployment targets for platforms other than the one we're building for.  <rdar://problem/20008508>
    let ourDeploymentTargetName = scope.evaluate(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME)
    for deploymentTargetNameToRemove in workspaceContext.core.platformRegistry.allDeploymentTargetMacroNames {
        if ourDeploymentTargetName.isEmpty || ourDeploymentTargetName != deploymentTargetNameToRemove {
            result.removeValue(forKey: deploymentTargetNameToRemove)
        }
    }

    // Don't export SDK_VARIANT if we're a public install of Xcode.
    if !settings.globalScope.evaluate(BuiltinMacros.__EXPORT_SDK_VARIANT_IN_SCRIPTS) {
        result["SDK_VARIANT"] = nil
    }

    // Ensure that BUILD_DESCRIPTION_CACHE_DIR is never exported as it is *not* something we want customers to use.
    result.removeValue(forKey: BuiltinMacros.BUILD_DESCRIPTION_CACHE_DIR.name)

    if scope.evaluate(BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE) {
        // Make sure the cache directory is not going to be deleted via an `xcodebuild` invocation from the script.
        result["COMPILATION_CACHE_KEEP_CAS_DIRECTORY"] = "YES"
    }

    return result
}

extension Settings {
    public func infoPlistFilePath(_ scope: MacroEvaluationScope? = nil, _ workspaceContext: WorkspaceContext) -> Path {
        let infoplistFile = (scope ?? globalScope).evaluate(BuiltinMacros.INFOPLIST_FILE)
        if !infoplistFile.isEmpty && !infoplistFile.isAbsolute {
            return (project?.sourceRoot ?? workspaceContext.workspace.path.dirname).join(infoplistFile)
        }
        return infoplistFile
    }
}
