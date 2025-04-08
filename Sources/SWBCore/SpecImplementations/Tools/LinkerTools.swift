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
import SWBProtocol
public import SWBUtil
public import SWBMacro

struct LdLinkerTaskPreviewPayload: Serializable, Encodable {
    enum LinkStyle: Int, Serializable, Encodable {
        case dylib
        case bundleLoader
        case staticLib
    }

    let architecture: String
    let buildVariant: String
    let objectFileDir: Path
    let linkStyle: LinkStyle

    init(architecture: String, buildVariant: String, objectFileDir: Path, linkStyle: LinkStyle) {
        self.architecture = architecture
        self.buildVariant = buildVariant
        self.objectFileDir = objectFileDir
        self.linkStyle = linkStyle
    }

    func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(architecture)
            serializer.serialize(buildVariant)
            serializer.serialize(objectFileDir)
            serializer.serialize(linkStyle)
        }
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.architecture = try deserializer.deserialize()
        self.buildVariant = try deserializer.deserialize()
        self.objectFileDir = try deserializer.deserialize()
        self.linkStyle = try deserializer.deserialize()
    }
}

fileprivate struct LdLinkerTaskPayload: DependencyInfoEditableTaskPayload {
    /// Path that points to the output linker file.
    let outputPath: Path

    /// Payload that contains the edit request for the output dependencies file.
    let dependencyInfoEditPayload: DependencyInfoEditPayload?

    /// Supports generatePreviewInfo()
    let previewPayload: LdLinkerTaskPreviewPayload?

    /// The preview build style in effect (dynamic replacement or XOJIT), if any.
    let previewStyle: PreviewStyleMessagePayload?

    /// Path to the object file emitted during LTO, used for optimization remarks.
    fileprivate let objectPathLTO: Path?

    init(
        outputPath: Path,
        dependencyInfoEditPayload: DependencyInfoEditPayload? = nil,
        previewPayload: LdLinkerTaskPreviewPayload? = nil,
        previewStyle: PreviewStyle? = nil,
        objectPathLTO: Path? = nil
    ) {
        self.outputPath = outputPath
        self.dependencyInfoEditPayload = dependencyInfoEditPayload
        self.previewPayload = previewPayload
        self.objectPathLTO = objectPathLTO
        switch previewStyle {
        case .dynamicReplacement:
            self.previewStyle = .dynamicReplacement
        case .xojit:
            self.previewStyle = .xojit
        case nil:
            self.previewStyle = nil
        }
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(5) {
            serializer.serialize(outputPath)
            serializer.serialize(dependencyInfoEditPayload)
            serializer.serialize(previewPayload)
            serializer.serialize(objectPathLTO)
            serializer.serialize(previewStyle)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.outputPath = try deserializer.deserialize()
        self.dependencyInfoEditPayload = try deserializer.deserialize()
        self.previewPayload = try deserializer.deserialize()
        self.objectPathLTO = try deserializer.deserialize()
        self.previewStyle = try deserializer.deserialize()
    }
}

fileprivate struct LibtoolLinkerTaskPayload: DependencyInfoEditableTaskPayload, Encodable {
    /// Payload that contains the edit request for the output dependencies file.
    let dependencyInfoEditPayload: DependencyInfoEditPayload?

    /// Supports generatePreviewInfo()
    let previewPayload: LdLinkerTaskPreviewPayload?

    init(
        dependencyInfoEditPayload: DependencyInfoEditPayload? = nil,
        previewPayload: LdLinkerTaskPreviewPayload? = nil
    ) {
        self.dependencyInfoEditPayload = dependencyInfoEditPayload
        self.previewPayload = previewPayload
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(dependencyInfoEditPayload)
            serializer.serialize(previewPayload)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.dependencyInfoEditPayload = try deserializer.deserialize()
        self.previewPayload = try deserializer.deserialize()
    }
}

public enum Linker: Sendable {
    case ld64, gnuld, gold, lld, linkExe
}

public struct DiscoveredLdLinkerToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let linker: Linker
    public let toolPath: Path
    public let toolVersion: Version?
    public let architectures: Set<String>
}

/// Parses stderr output as generated by ld(1).
@_spi(Testing) public final class LdLinkerOutputParser : GenericOutputParser {

    /// Regular expression that matches a line indicating the start of a list of undefined symbols.  The section ends with a "symbol(s) not found" error message.
    static let undefSymbolsSectionStartRegEx = RegEx(patternLiteral: "^[ ]*Undefined symbols.*:$")

    /// Regular expression that matches a line that names an undefined symbol.  We currently ignore the references, which follow on one or more lines.
    static let undefSymbolNameRegEx = RegEx(patternLiteral: "^[ ]*\"([^\"]*)\", referenced from:$")

    /// Regular expression that matches a message emitted about a problem.  Warning messages have a "warning: " prefix, errors don't have any prefix.
    static let problemMessageRegEx = RegEx(patternLiteral: "^(ld|clang):[ ]*((error|warning|note|notice): )?(.+)$")

    /// Regular expression that matches the extracted diagnostic message about a missing framework linkage.  Example: `framework not found Foo`
    static let frameworkNotFoundRegEx = (RegEx(patternLiteral: "^[fF]ramework not found (.+)$"), false)

    /// Regular expression that matches the extracted diagnostic message about a missing framework linkage.  Example: `framework 'Foo' not found`
    static let newFrameworkNotFoundRegEx = (RegEx(patternLiteral: "^[fF]ramework '(.+)' not found$"), false)

    /// Accumulator of names of undefined symbols.  We currently don't capture their associated references.
    var undefinedSymbols: [String] = []

    /// True whenever we're inside the list of undefined symbols.
    var collectingUndefinedSymbols = false

    /// Maximum number of undefined symbols to emit.  Might be configurable in the future.
    let undefinedSymbolCountLimit = 100

    override func parseLine<S: Collection>(_ lineBytes: S) -> Bool where S.Element == UInt8 {

        // Create a string that we can examine.  Use the non-failable constructor, so that we are robust against potentially invalid UTF-8.
        let lineString = String(decoding: lineBytes, as: Unicode.UTF8.self)

        // If we're collecting undefined symbols, we check for the pattern that indicates a new symbol.  We don't currently collect information about where the symbols were referenced from, but we could do so (and would emit them as annotations on the error message that we emit for the symbol, similar to the "here is the location of the previous definition" annotations that compilers sometimes emit).
        if collectingUndefinedSymbols {
            // Check if we have found a symbol.
            if let match = LdLinkerOutputParser.undefSymbolNameRegEx.firstMatch(in: lineString) {
                // We've found a symbol, so we add it to the list.
                undefinedSymbols.append(match[0])
            }
            else if let match = LdLinkerOutputParser.problemMessageRegEx.firstMatch(in: lineString), match[3].hasPrefix("symbol(s) not found") {
                // It's time to emit all the symbols.  We emit each as a separate message.
                for symbol in undefinedSymbols.prefix(undefinedSymbolCountLimit) {
                    delegate.diagnosticsEngine.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Undefined symbol: \(symbol)"), appendToOutputStream: false))
                }
                if undefinedSymbols.count > undefinedSymbolCountLimit {
                    delegate.diagnosticsEngine.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("(\(undefinedSymbols.count - undefinedSymbolCountLimit) additional undefined symbols are shown in the transcript"), appendToOutputStream: false))
                }
                collectingUndefinedSymbols = false
                undefinedSymbols = []
            }
            else {
                // Ignore references for now.
            }
        }
        else if LdLinkerOutputParser.undefSymbolsSectionStartRegEx.firstMatch(in: lineString) != nil {
            // We've found the start of a list of undefined symbols; we'll collect them and emit them at the end of the list.
            collectingUndefinedSymbols = true
        }
        else if let match = LdLinkerOutputParser.problemMessageRegEx.firstMatch(in: lineString) {
            // We've found an error outside of the undefined-symbols list.  We emit it in accordance with its type.
            // match[0] is severity prefix (if any), match[1] is severity name (if any), match[2] is the message
            let severity = match[2].isEmpty ? "error" : match[2]
            let behavior = Diagnostic.Behavior(name: severity) ?? .note
            let message = match[3].prefix(1).localizedCapitalized + match[3].dropFirst()
            let diagnostic = Diagnostic(behavior: behavior, location: .unknown, data: DiagnosticData(message), appendToOutputStream: false)
            delegate.diagnosticsEngine.emit(diagnostic)
        }
        return true
    }

    public override func close(result: TaskResult?) {
        super.close(result: result)
        // Read optimization remarks if the build succeeded.
        if result.shouldSkipParsingDiagnostics { return }
        guard let payload = self.task.payload as? LdLinkerTaskPayload else { return }
        // If the object file path is not there, remarks might not be generated.
        guard let path = payload.objectPathLTO else { return }
        delegate.processOptimizationRemarks(at: path, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
    }
}

public final class LdLinkerSpec : GenericLinkerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.pbx.linkers.ld"

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        // TODO: We should also provide an "auto" option which chooses based on the source files in the target
        switch cbc.scope.evaluate(BuiltinMacros.LINKER_DRIVER) {
        case .clang:
            return cbc.producer.hostOperatingSystem.imageFormat.executableName(basename: "clang")
        case .swiftc:
            return cbc.producer.hostOperatingSystem.imageFormat.executableName(basename: "swiftc")
        }
    }

    override public var toolBasenameAliases: [String] {
        // We use clang as our linker, so return ld and libtool in aliases in
        // order to parse the errors from the actual linker.
        return ["ld", "libtool"]
    }

    public func sparseSDKSearchPathArguments(_ cbc: CommandBuildContext) -> [String] {
        var specialArgs = [String]()

        // Add the paths for any sparse SDKs.
        for sparseSDK in cbc.producer.sparseSDKs {
            // Add any library search paths that are specified by the sparse SDK, and those that are documented linker defaults (if they exist in the SDK).
            let librarySearchPaths = sparseSDK.librarySearchPaths
            // FIXME: Implement support for the linker default paths if needed.  <rdar://problem/34171003>
            //            for defaultSubpath in ["usr/lib", "usr/local/lib"] {
            //                let defaultPath = sparseSDK.path.join(defaultSubpath)
            //                if FS.exists(defaultPath) {
            //                    librarySearchPaths.append(defaultPath)
            //                }
            //            }
            for path in librarySearchPaths { specialArgs.append(contentsOf: ["-L", path.str]) }

            // Do the same for the framework search paths.
            let frameworkSearchPaths = sparseSDK.frameworkSearchPaths
            // FIXME: Implement support for the linker default paths if needed.  <rdar://problem/34171003>
            //            for defaultSubpath in ["Library/Frameworks", "System/Library/Frameworks"] {
            //                let defaultPath = sparseSDK.path.join(defaultSubpath)
            //                if FS.exists(defaultPath) {
            //                    frameworkSearchPaths.append(defaultPath)
            //                }
            //            }
            for path in frameworkSearchPaths { specialArgs.append(contentsOf: ["-F", path.str]) }
        }

        return specialArgs
    }

    // FIXME: Is there a better way to figure out if we are linking Swift?
    private func isUsingSwift(_ usedTools: [CommandLineToolSpec: Set<FileTypeSpec>]) -> Bool {
        return usedTools.keys.map({ type(of: $0) }).contains(where: { $0 == SwiftCompilerSpec.self })
    }

    static public func computeRPaths(_ cbc: CommandBuildContext,_ delegate: any TaskGenerationDelegate, inputRunpathSearchPaths: [String], isUsingSwift: Bool ) async -> [String] {
        // Product types can provide their own set of rpath values, we need to ensure that our rpath flags for Swift in the OS appear before those. Also, due to the fact that we are staging this rollout, we need to specifically override any Swift libraries that may be in the bundle _when_ the Swift ABI version matches on the system with that in which the tool was built with.

        var runpathSearchPaths = inputRunpathSearchPaths
        // NOTE: For swift.org toolchains, we always add the search paths to the Swift SDK location as the overlays do not have the install name set. This also works when `SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME=YES` as `DYLD_LIBRARY_PATH` is used to override these settings during debug time. If users wish to use the development runtime while not debugging, they need to manually set their rpaths as this is not a supported configuration.
        // Also, if the deployment target does not support Swift in the OS, the rpath entries need to be added as well.
        // And, if the deployment target does not support Swift Concurrency natively, then the rpath needs to be added as well so that the shim library can find the real implementation. Note that we assume `true` in the case where `supportsSwiftInTheOS` is `nil` as we don't have the platform data to make the correct choice; so fallback to existing behavior.
        // The all above discussion is only relevant for platforms that support Swift in the OS.
        let supportsSwiftConcurrencyNatively = cbc.producer.platform?.supportsSwiftConcurrencyNatively(cbc.scope, forceNextMajorVersion: false, considerTargetDeviceOSVersion: false) ?? true
        let shouldEmitRPathForSwiftConcurrency = UserDefaults.allowRuntimeSearchPathAdditionForSwiftConcurrency && !supportsSwiftConcurrencyNatively
        if (cbc.producer.platform?.supportsSwiftInTheOS(cbc.scope, forceNextMajorVersion: true, considerTargetDeviceOSVersion: false) != true || cbc.producer.toolchains.usesSwiftOpenSourceToolchain || shouldEmitRPathForSwiftConcurrency) && isUsingSwift && cbc.producer.platform?.minimumOSForSwiftInTheOS != nil {
                // NOTE: For swift.org toolchains, this is fine as `DYLD_LIBRARY_PATH` is used to override these settings.
            let swiftABIVersion =  await (cbc.producer.swiftCompilerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)?.swiftABIVersion
                runpathSearchPaths.insert( swiftABIVersion.flatMap { "/usr/lib/swift-\($0)" } ?? "/usr/lib/swift", at: 0)
        }

        return runpathSearchPaths
    }

    override public func constructLinkerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, libraries: [LibrarySpecifier], usedTools: [CommandLineToolSpec: Set<FileTypeSpec>]) async {
        // Validate that OTHER_LDFLAGS doesn't contain flags for constructs which we have dedicated settings for. This should be expanded over time.
        let dyldEnvDiagnosticBehavior: Diagnostic.Behavior = SWBFeatureFlag.useStrictLdEnvironmentBuildSetting.value ? .error : .warning
        let originalLdFlags = cbc.scope.evaluate(BuiltinMacros.OTHER_LDFLAGS)
        enumerateLinkerCommandLine(arguments: originalLdFlags) { arg, value in
            switch arg {
            case "-dyld_env":
                delegate.emit(Diagnostic(behavior: dyldEnvDiagnosticBehavior, location: .buildSetting(BuiltinMacros.OTHER_LDFLAGS), data: DiagnosticData("The \(BuiltinMacros.OTHER_LDFLAGS.name) build setting is not allowed to contain \(arg), use the dedicated LD_ENVIRONMENT build setting instead.")))
            case "-client_name":
                delegate.emit(Diagnostic(behavior: dyldEnvDiagnosticBehavior, location: .buildSetting(BuiltinMacros.OTHER_LDFLAGS), data: DiagnosticData("The \(BuiltinMacros.OTHER_LDFLAGS.name) build setting is not allowed to contain \(arg), use the dedicated LD_CLIENT_NAME build setting instead.")))
            default:
                break
            }
        }

        // Compute characteristics of the binary which affect args we compute below.

        // For previewed apps in framework mode, the standard binary is linked as a dylib, and in its place we link a shim using constructPreviewShimLinkerTasks
        let previewDylib = cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH)
        let isPreviewDylib = !previewDylib.isEmpty

        let machOTypeString = isPreviewDylib
            ? "mh_dylib"
            : cbc.scope.evaluate(BuiltinMacros.MACH_O_TYPE)
        let machOType = cbc.scope.namespace.parseLiteralString(machOTypeString)

        let entitlements = isPreviewDylib
            ? cbc.scope.namespace.parseLiteralString("")
            : cbc.scope.namespace.parseLiteralString(cbc.scope.evaluate(BuiltinMacros.LD_ENTITLEMENTS_SECTION))

        let entitlementsDer = isPreviewDylib
            ? cbc.scope.namespace.parseLiteralString("")
            : cbc.scope.namespace.parseLiteralString(cbc.scope.evaluate(BuiltinMacros.LD_ENTITLEMENTS_SECTION_DER))

        let installName: MacroStringExpression
        if isPreviewDylib {
            installName = cbc.scope.namespace.parseLiteralString(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME))
        } else {
            installName = cbc.scope.namespace.parseLiteralString(cbc.scope.evaluate(BuiltinMacros.LD_DYLIB_INSTALL_NAME))
        }

        // Construct the "special args".
        var specialArgs = [String]()
        var inputPaths = cbc.inputs.map({ $0.absolutePath })

        specialArgs.append(contentsOf: sparseSDKSearchPathArguments(cbc))

        // Define the linker file list.
        let fileListPath = cbc.scope.evaluate(BuiltinMacros.__INPUT_FILE_LIST_PATH__)
        if !fileListPath.isEmpty {
            let contents = OutputByteStream()
            for input in cbc.inputs {
                // ld64 reads lines from the file using fgets, without doing any other processing.
                contents <<< input.absolutePath.strWithPosixSlashes <<< "\n"
            }
            let fileListPath = fileListPath
            cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: fileListPath), delegate, contents: contents.bytes, permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
            inputPaths.append(fileListPath)
        }

        // Add the library arguments.
        let libraryArgs = LdLinkerSpec.computeLibraryArgs(libraries, scope: cbc.scope)
        specialArgs += libraryArgs.args
        if SWBFeatureFlag.enableLinkerInputsFromLibrarySpecifiers.value {
            inputPaths += libraryArgs.inputs
        }

        // FIXME: When using LTO, keep an object file on the side to preserve debug info.

        // Disable linker ad-hoc signing if we will be signing the product.  This is a performance optimization to eliminate redundant or unnecessary work.
        // Presently the linker only ad-hoc signs when linking a final linked image (e.g., not an object file from 'ld -r') for an arm architecture for macOS.  That's a lot of condition for no practical gain, so we simplify by always disabling linker ad-hoc signing for final linked products when we have a signing identity.
        let willSignProduct = !cbc.scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY).isEmpty
        // The MachO type being mh_object is a proxy for doing an 'ld -r'.  (We should really treat 'ld -r' as its own logical tool with its own xcspec.)
        let linkerMaySignBinary = (machOTypeString != "mh_object")
        if willSignProduct, linkerMaySignBinary {
            specialArgs += ["-Xlinker", "-no_adhoc_codesign"]
        }

        // Add linker flags desired by the product type.
        let productTypeArgs = cbc.producer.productType?.computeAdditionalLinkerArgs(cbc.producer, scope: cbc.scope)
        specialArgs += productTypeArgs?.args ?? []
        inputPaths += productTypeArgs?.inputs ?? []

        var outputs: [any PlannedNode] = [delegate.createNode(cbc.output)] + cbc.commandOrderingOutputs

        // Add the additional outputs defined by the spec.  These are not declared as outputs but should be processed by the tool separately.
        let additionalEvaluatedOutputsResult = await additionalEvaluatedOutputs(cbc, delegate)
        outputs.append(contentsOf: additionalEvaluatedOutputsResult.outputs.map({ delegate.createNode($0) }))

        if let infoPlistContent = additionalEvaluatedOutputsResult.generatedInfoPlistContent {
            delegate.declareGeneratedInfoPlistContent(infoPlistContent)
        }

        // Add flags to emit dependency info.
        let dependencyInfo = await self.dependencyData(cbc: cbc, delegate: delegate, outputs: &outputs)

        // FIXME: Honor LD_QUITE_LINKER_ARGUMENTS_FOR_COMPILER_DRIVER == NO ?

        let optionContext = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)

        // Gather additional linker arguments from the used tools.
        //
        // FIXME: Figure out the right way to do this, going forward. Xcode does this by injecting build settings, but we don't have infrastructure for that yet. We could easily changed commandLineFromOptions to support custom overrides, if we do want to go that approach, although it might also make sense to design a more strict / efficient / type safe mechanism that directly allowed the generic spec data to delegate to methods on the spec class.
        var additionalLinkerArgsArray: [[String]] = []
        for info in usedTools.sorted(byKey: \.identifier) {
            // If we are producing an object file then the additional linker args are not added. This is because
            // some linkers like GNU Gold will not accept link libraries when producing object files through
            // partial linking and the "-r" flag.
            if let linkerContext = (optionContext as? DiscoveredLdLinkerToolSpecInfo), linkerContext.linker != .ld64 && machOTypeString == "mh_object" {
                continue
            }

            let spec = info.key
            let inputFileTypes = info.value
            let (args, inputs) = await spec.computeAdditionalLinkerArgs(cbc.producer, scope: cbc.scope, inputFileTypes: [FileTypeSpec](inputFileTypes), optionContext: spec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), delegate: delegate)
            additionalLinkerArgsArray.append(contentsOf: args)
            inputPaths.append(contentsOf: inputs)
        }

        let isLinkUsingSwift = isUsingSwift(usedTools)
        if !isLinkUsingSwift {
            // Check if we need to link with Swift's standard library
            // when linking a pure Objective-C/C++ target. This might be needed
            // when such target is using the C++ variant of the Swift standard library
            // APIs from the generated header that was generated in one of the
            // dependencies, as in that case the C++ code will directly reference Swift standard
            // library symbols. This check is done using a heuristic - if one of the dependencies
            // has C++ interoperability enabled, we should assume that there's a possibility that
            // this target could be using the exposed Swift APIs in the C++ section of the generated
            // header.
            if let target = cbc.producer.configuredTarget {
                let depScopes = cbc.producer.targetSwiftDependencyScopes(for: target, arch: cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH), variant:  cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT))
                for scope in depScopes {
                    if scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTEROP_MODE) == "objcxx" {
                        let optionContext = await cbc.producer.swiftCompilerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, scope, delegate)
                        additionalLinkerArgsArray.append(contentsOf: await cbc.producer.swiftCompilerSpec.computeAdditionalLinkerArgs(cbc.producer, scope: cbc.scope, inputFileTypes: [FileTypeSpec](), optionContext: optionContext, delegate: delegate).args)
                        additionalLinkerArgsArray.append(["-l\(cbc.scope.evaluate(BuiltinMacros.SWIFT_STDLIB))"])
                        break
                    }
                }
            }
        }

        // Deduplicate the linker args array using ordered set.
        let additionalLinkerArgs = OrderedSet(additionalLinkerArgsArray).flatMap({ $0 })
        let additionalLinkerArgsExpr = cbc.scope.namespace.parseLiteralStringList(additionalLinkerArgs)

        // See related:
        var runpathSearchPaths: [String] = []
        if machOTypeString != "mh_object" {
            runpathSearchPaths =  await LdLinkerSpec.computeRPaths(cbc, delegate, inputRunpathSearchPaths: cbc.scope.evaluate(BuiltinMacros.LD_RUNPATH_SEARCH_PATHS), isUsingSwift: isLinkUsingSwift)

            // If we're merging libraries and we're reexporting any libraries, then add an rpath to the ReexportedBinaries directory.
            // This coordinates with the logic in SourcesTaskProducer which copies content to that directory.
            // FIXME: These rpaths should be evaluated in `computeRPaths`.
            if cbc.scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES), !cbc.scope.evaluate(BuiltinMacros.DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES) {
                if libraries.first(where: { $0.mode == .reexport_merge }) != nil {
                    runpathSearchPaths.insert( "@loader_path/\(reexportedBinariesDirectoryName)", at: 0)
                }
            }
        }
        let runpathSearchPathsExpr = cbc.scope.namespace.parseStringList(OrderedSet(runpathSearchPaths).elements)

        let tbdDir = cbc.scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_DIR)
        var librarySearchPaths = cbc.scope.evaluate(BuiltinMacros.LIBRARY_SEARCH_PATHS)
        if !tbdDir.isEmpty {
            librarySearchPaths.insert(tbdDir.str, at: 0)
        }
        let librarySearchPathsExpr = cbc.scope.namespace.parseStringList(librarySearchPaths)

        var frameworkSearchPaths = cbc.scope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS)
        if !tbdDir.isEmpty {
            frameworkSearchPaths.insert(tbdDir.str, at: 0)
        }
        let frameworkSearchPathsExpr = cbc.scope.namespace.parseStringList(frameworkSearchPaths)

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.LD_RUNPATH_SEARCH_PATHS:
                return runpathSearchPathsExpr
            case BuiltinMacros.LIBRARY_SEARCH_PATHS:
                return librarySearchPathsExpr
            case BuiltinMacros.FRAMEWORK_SEARCH_PATHS:
                return frameworkSearchPathsExpr
            case BuiltinMacros.AdditionalCommandLineArguments:
                return additionalLinkerArgsExpr
            case BuiltinMacros.MACH_O_TYPE:
                return machOType
            case BuiltinMacros.LD_DYLIB_INSTALL_NAME:
                return installName
            case BuiltinMacros.LD_ENTITLEMENTS_SECTION:
                return entitlements
            case BuiltinMacros.LD_ENTITLEMENTS_SECTION_DER:
                return entitlementsDer
            case BuiltinMacros.LD_DYLIB_INSTALL_NAME where isPreviewDylib:
                // rdar://127733311 (Use stable debug dylib name when `LD_CLIENT_NAME` is specified on the executable target)
                guard let name = cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME).nilIfEmpty else {
                    return nil
                }
                return cbc.scope.namespace.parseLiteralString(name)
            case BuiltinMacros.OTHER_LDFLAGS where isPreviewDylib:
                let ldFlagsToEvaluate: [String]
                if dyldEnvDiagnosticBehavior == .warning {
                    ldFlagsToEvaluate = filterLinkerFlagsWhenUnderPreviewsDylib(originalLdFlags)
                }
                else {
                    ldFlagsToEvaluate = originalLdFlags
                }

                // LD_ENTRY_POINT covers user-specified entry points as well as built-in entry
                // points like _NSExtensionMain as defined in the app extension product type spec.
                // We need an alias specified to force a global symbol so the previews stub
                // executor can find something, even if the symbol would have been hidden by
                // `-fvisibility=hidden`.
                // rdar://122928395 ("Could not find entry point 'main'" in preview dylib)
                let entryPoint = cbc.scope.evaluate(BuiltinMacros.LD_ENTRY_POINT)
                let ldFlagsForEntryPointAlias = [
                    "-Xlinker", "-alias",
                    "-Xlinker", entryPoint.nilIfEmpty ?? "_main",
                    "-Xlinker", "___debug_main_executable_dylib_entry_point",
                ]

                // rdar://127733311 (Use stable debug dylib name when `LD_CLIENT_NAME` is specified on the executable target)
                //
                // If the settings phase calculated a mapped install name, then we need to
                // communicate that to the linker with an `$ld$previous` symbol so the debug dylib
                // can have a different path than it's install name. This allows the dylib to
                // satisfy an `-allowable_client` check yet still be a stable path within the
                // bundle for other tooling.
                //
                // Aliasing a known symbol to this `$ld$previous` symbol is sufficient.
                let ldFlagsForAllowableClientOverride: [String]
                if let mappedInstallName = cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME).nilIfEmpty {
                    let platform = cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_PLATFORM)
                    ldFlagsForAllowableClientOverride = [
                        "-Xlinker", "-alias",
                        "-Xlinker", "___debug_main_executable_dylib_entry_point",
                        "-Xlinker", "$ld$previous$\(mappedInstallName)$$\(platform)$1.0$9999.0$$",
                    ]
                } else {
                    ldFlagsForAllowableClientOverride = []
                }

                return cbc.scope.namespace.parseLiteralStringList(
                    ldFlagsToEvaluate + ldFlagsForEntryPointAlias + ldFlagsForAllowableClientOverride
                )
            default:
                return nil
            }
        }

        // Generate the command line.
        var commandLine = commandLineFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs, lookup: lookup).map(\.asString)

        // Add flags to emit SDK imports info.
        let sdkImportsInfoFile = cbc.scope.evaluate(BuiltinMacros.LD_SDK_IMPORTS_FILE)
        let supportsSDKImportsFeature = (try? optionContext?.toolVersion >= .init("1164")) == true
        var usesLDClassic = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH) == "armv7k"
        enumerateLinkerCommandLine(arguments: commandLine) { arg, value in
            switch arg {
            case "-ld_classic": usesLDClassic = true
            case "-r": usesLDClassic = true
            default: break
            }
        }
        if !usesLDClassic, supportsSDKImportsFeature, !sdkImportsInfoFile.isEmpty, cbc.scope.evaluate(BuiltinMacros.ENABLE_SDK_IMPORTS), cbc.producer.isApplePlatform {
            commandLine.insert(contentsOf: ["-Xlinker", "-sdk_imports", "-Xlinker", sdkImportsInfoFile.str, "-Xlinker", "-sdk_imports_each_object"], at: commandLine.count - 2) // This preserves the assumption that the last argument is the linker output which a few tests make.
            outputs.append(delegate.createNode(sdkImportsInfoFile))

            await cbc.producer.processSDKImportsSpec.createTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: []), delegate, ldSDKImportsPath: sdkImportsInfoFile)
        }

        // Select the driver to use based on the input file types, replacing the value computed by commandLineFromTemplate().
        let usedCXX = usedTools.values.contains(where: { $0.contains(where: { $0.languageDialect?.isPlusPlus ?? false }) })
        commandLine[0] = resolveExecutablePath(cbc, computeLinkerPath(cbc, usedCXX: usedCXX)).str

        let entitlementsSection = cbc.scope.evaluate(BuiltinMacros.LD_ENTITLEMENTS_SECTION)
        if !entitlementsSection.isEmpty {
            inputPaths.append(Path(entitlementsSection))
        }

        let entitlementsSectionDer = cbc.scope.evaluate(BuiltinMacros.LD_ENTITLEMENTS_SECTION_DER)
        if !entitlementsSectionDer.isEmpty {
            inputPaths.append(Path(entitlementsSectionDer))
        }

        // If we are linking Swift and build for debugging, pass the right .swiftmodule file for the current architecture to the
        // linker. This is needed so that debugging these modules works correctly. Note that `swiftModulePaths` will be empty for
        // anything but static archives and object files, because dynamic libraries and frameworks do not require this.
        if isLinkUsingSwift && cbc.scope.evaluate(BuiltinMacros.GCC_GENERATE_DEBUGGING_SYMBOLS) && !cbc.scope.evaluate(BuiltinMacros.PLATFORM_REQUIRES_SWIFT_MODULEWRAP) {
            for library in libraries {
                if let swiftModulePath = library.swiftModulePaths[cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)] {
                    commandLine += ["-Xlinker", "-add_ast_path", "-Xlinker", swiftModulePath.str]
                }
                if let additionalArgsPath = library.swiftModuleAdditionalLinkerArgResponseFilePaths[cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)] {
                    commandLine += ["@\(additionalArgsPath.str)"]
                }
            }
        }

        // When optimization remarks are enabled with clang in LTO mode, we need
        // to pass the right flags to the **linker** invocation (which goes
        // through the driver anyway), since we are interested in the remarks
        // generated during link-time optimization.
        // We'll choose the output path of the remarks to be next to the
        // temporary object file generated for LTO, which is needed for dsymutil
        // to generate a dSYM anyway.
        let LTO = cbc.scope.evaluate(BuiltinMacros.LLVM_LTO)
        let objectPathLTO = cbc.scope.evaluate(BuiltinMacros.LD_LTO_OBJECT_FILE)
        let shouldGenerateRemarks = cbc.scope.evaluate(BuiltinMacros.CLANG_GENERATE_OPTIMIZATION_REMARKS) && (LTO == "YES" || LTO == "YES_THIN")
        if shouldGenerateRemarks {
            let remarkFilePath = Path(objectPathLTO.str + ".opt.bitstream")
            commandLine += ["-fsave-optimization-record=bitstream", "-foptimization-record-file=" + remarkFilePath.str]
            let filter = cbc.scope.evaluate(BuiltinMacros.CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER)
            if !filter.isEmpty {
                commandLine += ["-foptimization-record-passes=\(filter)"]
            }
        }

        let environment: EnvironmentBindings = self.environmentFromSpec(cbc, delegate)

        // Compute the inputs and outputs.
        var inputs: [any PlannedNode] = inputPaths.map{ delegate.createNode($0) }

        await inputs.append(contentsOf: additionalInputDependencies(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(delegate.createNode))

        // Add dependencies for any arguments indicating a file path.
        Self.addAdditionalDependenciesFromCommandLine(cbc, commandLine, environment, &inputs, &outputs, delegate)

        let architecture = cbc.scope.evaluate(BuiltinMacros.arch)
        let buildVariant = cbc.scope.evaluate(BuiltinMacros.variant)
        let objectFileDir = cbc.scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR)
        let linkStyle: LdLinkerTaskPreviewPayload.LinkStyle = machOTypeString == "mh_execute" && !isPreviewDylib ? .bundleLoader : .dylib
        let previewPayload = LdLinkerTaskPreviewPayload(architecture: architecture, buildVariant: buildVariant, objectFileDir: objectFileDir, linkStyle: linkStyle)

        // Only add the edit payload if the dependency info was configured.
        let editPayload: DependencyInfoEditPayload?
        if dependencyInfo != nil {
            // Silently fix up the dependency info in order to avoid generating incorrect dependencies in certain cases:
            // <rdar://42453410> ld64 may emit its output path as an *input* as well as an output
            // <rdar://44232202> ld64 may emit its target's corresponding .tbd file as an input
            // <rdar://58021911> linking against symlinks prevents proper discovered dependency resolution
            // Note: The unit test for this BuildOperationTests.testCircularLink() was removed in <rdar://128608480> as we felt maintaining it was more effort than it was worth. If we find new scenarios where this logic needs to be updated, new tests will need to be written.
            editPayload = DependencyInfoEditPayload(
                removablePaths: [
                    cbc.output,
                    cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_PATH)),
                    cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.WRAPPER_NAME)).join(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_NAME)),
                    Path(cbc.scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH)),
                    Path(cbc.scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH))
                ], removableBasenames: [
                    cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_NAME),
                    Path(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_NAME)).basenameWithoutSuffix + ".tbd",
                ],
                developerPath: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR)
            )
        } else {
            editPayload = nil
        }

        let payload = LdLinkerTaskPayload(
            outputPath: cbc.output,
            dependencyInfoEditPayload: editPayload,
            previewPayload: previewPayload,
            previewStyle: cbc.scope.previewStyle,
            objectPathLTO: shouldGenerateRemarks ? objectPathLTO : nil
        )

        // Add dependencies on any directories in our input search paths for which the build system is creating those directories.
        let ldSearchPaths = Set(cbc.scope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS) + cbc.scope.evaluate(BuiltinMacros.LIBRARY_SEARCH_PATHS))
        let otherInputs = delegate.buildDirectories.sorted().compactMap { path in ldSearchPaths.contains(path.str) ? delegate.createBuildDirectoryNode(absolutePath: path) : nil } + cbc.commandOrderingInputs

        // Create the task.
        delegate.createTask(type: self, dependencyData: dependencyInfo, payload: payload, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLine, environment: environment, workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs + otherInputs, outputs: outputs, action: delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }

    public static func addAdditionalDependenciesFromCommandLine(_ cbc: CommandBuildContext, _ commandLine: [String], _ environment: EnvironmentBindings, _ inputs: inout [any PlannedNode], _ outputs: inout [any PlannedNode], _ delegate: any TaskGenerationDelegate) {
        guard cbc.scope.evaluate(BuiltinMacros._DISCOVER_COMMAND_LINE_LINKER_INPUTS) else {
            return
        }

        enumerateLinkerCommandLine(arguments: commandLine, handleWl: cbc.scope.evaluate(BuiltinMacros._DISCOVER_COMMAND_LINE_LINKER_INPUTS_INCLUDE_WL)) { arg, value in
            func emitDependencyDiagnostic(type: String, node: PlannedPathNode) {
                if delegate.userPreferences.enableDebugActivityLogs {
                    delegate.note("Added \(type) dependency '\(node.path.str)' from command line argument \(arg)", location: .unknown)
                }
            }

            func node(offset: Int) -> (PlannedPathNode)? {
                if let path = value(offset) {
                    return delegate.createNode(Path(path).normalize())
                }
                return nil
            }

            func addInput(offset: Int) {
                if let node = node(offset: offset), !inputs.contains(where: { $0.path == node.path }) {
                    emitDependencyDiagnostic(type: "input", node: node)
                    inputs.append(node)
                }
            }

            func addOutput(offset: Int) {
                if let node = node(offset: offset), !outputs.contains(where: { $0.path == node.path }) {
                    emitDependencyDiagnostic(type: "output", node: node)
                    outputs.append(node)
                }
            }

            // Current as of ld64-852 via manual scanning of the man page for arguments accepting paths
            switch arg {
            case "-sectcreate", "-sectorder":
                addInput(offset: 3)
            case "-move_to_ro_segment", "-move_to_rw_segment":
                addInput(offset: 2)
            case "-add_ast_path" where !commandLine.contains("-reproducible") && !environment.bindingsDictionary.contains("ZERO_AR_DATE"):
                // If -reproducible or ZERO_AR_DATE is active, ld64 does not read the file at all
                addInput(offset: 1)
            case "-alias_list",
                // FIXME: Handle -bundle_loader as well: presently, it's often set to a path which has an ancestor that is a symlink node (e.g. $(BUILT_PRODUCTS_DIR/foo.app), making it tricky to track the actual underlying path in install-style builds.
                //"-bundle_loader",
                "-dirty_data_list",
                "-dtrace",
                "-exported_symbols_list",
                "-force_load",
                "-interposable_list",
                "-lazy_library",
                "-load_hidden",
                "-lto_library",
                "-needed_library",
                "-order_file",
                "-reexport_library",
                "-merge_library",
                "-no_merge_library",
                "-reexported_symbols_list",
                "-unexported_symbols_list",
                "-upward_library",
                "-weak_library":
                addInput(offset: 1)
            case "-dot", "-map", "-object_path_lto":
                addOutput(offset: 1)
            default:
                break
            }
        }
    }

    public func constructPreviewShimLinkerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, libraries: [LibrarySpecifier], usedTools: [CommandLineToolSpec: Set<FileTypeSpec>], rpaths: [String], ldflags: [String]?) async {
        // Construct the "special args".
        var specialArgs = [String]()
        var inputPaths = cbc.inputs.map({ $0.absolutePath })

        // Add the library arguments.
        let libraryArgs = LdLinkerSpec.computeLibraryArgs(libraries, scope: cbc.scope)
        specialArgs += libraryArgs.args
        if SWBFeatureFlag.enableLinkerInputsFromLibrarySpecifiers.value {
            inputPaths += libraryArgs.inputs
        }

        // Disable linker ad-hoc signing if we will be signing the product.  This is a performance optimization to eliminate redundant or unnecessary work.
        // Presently the linker only ad-hoc signs when linking a final linked image (e.g., not an object file from 'ld -r') for an arm architecture for macOS.  That's a lot of condition for no practical gain, so we simplify by always disabling linker ad-hoc signing for final linked products when we have a signing identity.
        let willSignProduct = !cbc.scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY).isEmpty
        if willSignProduct {
            specialArgs += ["-Xlinker", "-no_adhoc_codesign"]
        }

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.LD_ENTRY_POINT where cbc.scope.previewStyle == .xojit:
                return cbc.scope.namespace.parseLiteralString("___debug_blank_executor_main")
            case BuiltinMacros.LD_EXPORT_GLOBAL_SYMBOLS:
                // We need to keep otherwise unused stub executor library symbols present so
                // PreviewsInjection can call them when doing the XOJIT handshake.
                return cbc.scope.namespace.parseLiteralString("YES")
            case BuiltinMacros.DEAD_CODE_STRIPPING:
                // We want to force dead code stripping to be off for the stub executor because we
                // need unused symbols present for PreviewsInjection to perform the handshake with
                // XOJIT.
                return cbc.scope.namespace.parseLiteralString("NO")
            case BuiltinMacros.OTHER_LDFLAGS:
                if let ldflags {
                    // In XOJIT mode, this is replaced entirely with a couple -sectcreate options. $(inherited) is not included because many linker flags may be problematic, such as -l flags which would cause the stub to directly link to a static library that the previews dylib also would link to.
                    return cbc.scope.namespace.parseLiteralStringList(ldflags)
                } else {
                    // In dynamic replacement mode, this is left unchanged (which might be incorrect, and needs to be investigated).
                    return nil
                }
            case BuiltinMacros.LD_WARN_UNUSED_DYLIBS:
                // We never want to warn on unused dylibs when linking the stub executor. It
                // pre-links the debug dylib but purposefully does not reference any symbols from
                // it to allow the possibility of interposition of the blank `__preview.dylib` with
                // the same install name when launched under previews.
                return cbc.scope.namespace.parseLiteralString("NO")
            case BuiltinMacros.LD_RUNPATH_SEARCH_PATHS:
                // We need to setup the shim's rpath so that it can find the preview dylib, and include the original rpaths.
                let originalRPaths = cbc.scope.evaluate(BuiltinMacros.LD_RUNPATH_SEARCH_PATHS)
                return cbc.scope.namespace.parseLiteralStringList(OrderedSet(rpaths + originalRPaths).elements)
            case BuiltinMacros.__INPUT_FILE_LIST_PATH__:
                // Should go to the preview dylib
                return cbc.scope.namespace.parseLiteralString("")
            case BuiltinMacros.LD_LTO_OBJECT_FILE:
                // Should go to the preview dylib
                return cbc.scope.namespace.parseLiteralString("")
            case BuiltinMacros.LD_CLIENT_NAME:
                // Should go to the preview dylib
                return cbc.scope.namespace.parseLiteralString("")
            case BuiltinMacros.LD_DEPENDENCY_INFO_FILE:
                return cbc.scope.namespace.parseLiteralString("")
            default:
                return nil
            }
        }

        let optionContext = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)

        // Generate the command line.
        var commandLine = commandLineFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs, lookup: lookup).map(\.asString)

        // Select the driver to use based on the input file types, replacing the value computed by commandLineFromTemplate().
        let usedCXX = usedTools.values.contains(where: { $0.contains(where: { $0.languageDialect?.isPlusPlus ?? false }) })
        commandLine[0] = resolveExecutablePath(cbc, computeLinkerPath(cbc, usedCXX: usedCXX)).str

        let entitlementsSection = cbc.scope.evaluate(BuiltinMacros.LD_ENTITLEMENTS_SECTION)
        if !entitlementsSection.isEmpty {
            inputPaths.append(Path(entitlementsSection))
        }

        let entitlementsSectionDer = cbc.scope.evaluate(BuiltinMacros.LD_ENTITLEMENTS_SECTION_DER)
        if !entitlementsSectionDer.isEmpty {
            inputPaths.append(Path(entitlementsSectionDer))
        }

        // Compute the inputs and outputs.
        let inputs = inputPaths.map{ delegate.createNode($0) } + cbc.commandOrderingInputs
        let outputs: [any PlannedNode] = [delegate.createNode(cbc.output)] + cbc.commandOrderingOutputs

        // Silently fix up the dependency info in order to avoid generating incorrect dependencies in certain cases:
        // <rdar://42453410> ld64 may emit its output path as an *input* as well as an output
        // <rdar://44232202> ld64 may emit its target's corresponding .tbd file as an input
        // <rdar://58021911> linking against symlinks prevents proper discovered dependency resolution
        // Note: The unit test for this BuildOperationTests.testCircularLink() was removed in <rdar://128608480> as we felt maintaining it was more effort than it was worth. If we find new scenarios where this logic needs to be updated, new tests will need to be written.
        let payload = LdLinkerTaskPayload(
            outputPath: cbc.output,
            dependencyInfoEditPayload: DependencyInfoEditPayload(
                removablePaths: [
                    cbc.output,
                    cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH)),
                    Path(cbc.scope.evaluate(BuiltinMacros.TAPI_OUTPUT_PATH)),
                    Path(cbc.scope.evaluate(BuiltinMacros.EAGER_LINKING_INTERMEDIATE_TBD_PATH))
                ],
                removableBasenames: [
                    cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_NAME),
                    Path(cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_NAME)).basenameWithoutSuffix + ".tbd",
                ],
                developerPath: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR)
            ),
            previewPayload: nil,
            previewStyle: cbc.scope.previewStyle
        )

        // Create the task.
        delegate.createTask(type: self, payload: payload, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }

    public func constructPreviewsBlankInjectionDylibTask(
        _ cbc: CommandBuildContext,
        delegate: any TaskGenerationDelegate
    ) async {
        // rdar://127248825 (Pre-link the debug dylib and emit a new empty dylib that Previews can load to get in front of dyld)

        // Construct the "special args".
        var specialArgs = [String]()

        // Disable linker ad-hoc signing if we will be signing the product.  This is a performance optimization to eliminate redundant or unnecessary work.
        // Presently the linker only ad-hoc signs when linking a final linked image (e.g., not an object file from 'ld -r') for an arm architecture for macOS.  That's a lot of condition for no practical gain, so we simplify by always disabling linker ad-hoc signing for final linked products when we have a signing identity.
        let willSignProduct = !cbc.scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY).isEmpty
        if willSignProduct {
            specialArgs += ["-Xlinker", "-no_adhoc_codesign"]
        }

        let optionContext = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.LD_DYLIB_INSTALL_NAME:
                let computedInstallName = cbc.scope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME)
                return cbc.scope.namespace.parseLiteralString(computedInstallName)
            case BuiltinMacros.MACH_O_TYPE:
                return cbc.scope.namespace.parseLiteralString("mh_dylib")
            case BuiltinMacros.__INPUT_FILE_LIST_PATH__,
                BuiltinMacros.ALL_OTHER_LDFLAGS,
                BuiltinMacros.OTHER_LDFLAGS,
                BuiltinMacros.LD_RUNPATH_SEARCH_PATHS,
                BuiltinMacros.LD_LTO_OBJECT_FILE:
                return cbc.scope.namespace.parseLiteralStringList([])
            default:
                return nil
            }
        }

        // Generate the command line.
        let commandLine = commandLineFromTemplate(
            cbc,
            delegate,
            optionContext: optionContext,
            specialArgs: specialArgs,
            lookup: lookup
        ).map(\.asString)

        let payload = LdLinkerTaskPayload(
            outputPath: cbc.output,
            dependencyInfoEditPayload: DependencyInfoEditPayload(
                removablePaths: [
                    cbc.output,
                ],
                removableBasenames: [],
                developerPath: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR)
            ),
            previewPayload: nil,
            previewStyle: .xojit
        )

        // Compute the inputs and outputs.
        let outputs: [any PlannedNode] = [delegate.createNode(cbc.output)] + cbc.commandOrderingOutputs

        // Create the task.
        delegate.createTask(
            type: self,
            payload: payload,
            ruleInfo: defaultRuleInfo(cbc, delegate),
            commandLine: commandLine,
            environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: [],
            outputs: outputs,
            action: nil,
            execDescription: resolveExecutionDescription(cbc, delegate),
            enableSandboxing: enableSandboxing
        )
    }

    public override func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        switch input {
        case let .thunkInfo(sourceFile, thunkVariantSuffix):
            return generateThunkPreviewInfo(for: task, sourceFile: sourceFile, thunkVariantSuffix: thunkVariantSuffix)
        case .targetDependencyInfo:
            return generateTargetDependencyPreviewInfo(for: task)
        }
    }

    private func generateThunkPreviewInfo(for task: any ExecutableTask, sourceFile: Path, thunkVariantSuffix: String) -> [TaskGeneratePreviewInfoOutput] {
        guard let payload = task.payload as? LdLinkerTaskPayload else { return [] }
        guard let previewPayload = payload.previewPayload else { return [] }

        // Linker tasks only participate in dynamic replacement previews, not XOJIT.
        guard payload.previewStyle == .dynamicReplacement else { return [] }

        let basePath = SwiftCompilerSpec.previewThunkPathWithoutSuffix(sourceFile: sourceFile, thunkVariantSuffix: thunkVariantSuffix, objectFileDir: previewPayload.objectFileDir)
        let inputPath = Path(basePath.str + ".o")
        let outputPath = Path(basePath.str + ".dylib")

        var commandLine = Array(task.commandLineAsStrings)

        let argPrefix = "-Xlinker"

        // Args without parameters
        for arg in ["-dynamiclib", "-bundle", "-r", "-dead_strip", "-nostdlib", "-rdynamic"] {
            while let index = commandLine.firstIndex(of: arg) {
                commandLine.remove(at: index)
            }
        }

        // Args without parameters (-Xlinker-prefixed, e.g. -Xlinker)
        for arg in ["-export_dynamic", "-sdk_imports_each_object"] {
            while let index = commandLine.firstIndex(of: arg) {
                guard index > 0, commandLine[index - 1] == argPrefix else { break }
                commandLine.removeSubrange(index - 1 ... index)
            }
        }

        // Args with a parameter
        for arg in ["-filelist", "-o", "-install_name", "-exported_symbols_list", "-unexported_symbols_list", "-bundle_loader"] {
            while let index = commandLine.firstIndex(of: arg) {
                guard index + 1 < commandLine.count else { break }

                // Remove arg and its parameter
                commandLine.remove(at: index)
                commandLine.remove(at: index)
            }
        }

        // Args with a parameter (-Xlinker-prefixed, e.g. -Xlinker arg -Xlinker param)
        for arg in ["-object_path_lto", "-add_ast_path", "-dependency_info", "-map", "-order_file", "-final_output", "-allowable_client", "-sdk_imports"] {
            while let index = commandLine.firstIndex(of: arg) {
                guard index > 0,
                    index + 2 < commandLine.count,
                    commandLine[index - 1] == argPrefix,
                    commandLine[index + 1] == argPrefix
                    else {
                        break
                }

                commandLine.removeSubrange(index - 1 ... index + 2)
            }
        }

        switch previewPayload.linkStyle {
        case .dylib:
            commandLine.append(contentsOf: [
                "-dynamiclib",
                payload.outputPath.str,
                ])

        case .bundleLoader:
            commandLine.append(contentsOf: [
                "-bundle",
                "-bundle_loader",
                payload.outputPath.str,
                ])
        case .staticLib:
            break
        }

        commandLine.append(inputPath.str)
        commandLine.append(contentsOf: [
            "-o",
            outputPath.str,
            ])

        let output = TaskGeneratePreviewInfoOutput(
            architecture: previewPayload.architecture,
            buildVariant: previewPayload.buildVariant,
            commandLine: commandLine,
            workingDirectory: task.workingDirectory,
            input: inputPath,
            output: outputPath,
            type: .Ld
        )

        return [output]
    }

    private func generateTargetDependencyPreviewInfo(for task: any ExecutableTask) -> [TaskGeneratePreviewInfoOutput] {
        guard let payload = task.payload as? LdLinkerTaskPayload else { return [] }
        guard let previewPayload = payload.previewPayload else { return [] }

        var commandLine = Array(task.commandLineAsStrings)

        let argPrefix = "-Xlinker"

        // Args without parameters
        for arg in [
            "-sdk_imports_each_object"
        ] {
            while let index = commandLine.firstIndex(of: arg) {
                guard index > 0, commandLine[index - 1] == argPrefix else { break }
                commandLine.removeSubrange(index - 1 ... index)
            }
        }

        // Args with a parameter (-Xlinker-prefixed, e.g. -Xlinker arg -Xlinker param)
        for arg in [
            "-sdk_imports"
        ] {
            while let index = commandLine.firstIndex(of: arg) {
                guard index > 0,
                    index + 2 < commandLine.count,
                    commandLine[index - 1] == argPrefix,
                    commandLine[index + 1] == argPrefix
                    else {
                        break
                }

                commandLine.removeSubrange(index - 1 ... index + 2)
            }
        }

        return [
            TaskGeneratePreviewInfoOutput(
                architecture: previewPayload.architecture,
                buildVariant: previewPayload.buildVariant,
                commandLine: commandLine,
                workingDirectory: task.workingDirectory,
                input: Path(""),
                output: payload.outputPath,
                type: .Ld
            )
        ]
    }

    private func computeLinkerPath(_ cbc: CommandBuildContext, usedCXX: Bool) -> Path {
        if usedCXX {
            let perArchValue = cbc.scope.evaluate(BuiltinMacros.PER_ARCH_LDPLUSPLUS)
            if !perArchValue.isEmpty {
                return Path(perArchValue)
            }

            let value = cbc.scope.evaluate(BuiltinMacros.LDPLUSPLUS)
            if !value.isEmpty {
                return Path(value)
            }

            return Path("clang++")
        } else {
            let perArchValue = cbc.scope.evaluate(BuiltinMacros.PER_ARCH_LD)
            if !perArchValue.isEmpty {
                return Path(perArchValue)
            }

            let value = cbc.scope.evaluate(BuiltinMacros.LD)
            if !value.isEmpty {
                return Path(value)
            }

            return Path(computeExecutablePath(cbc))
        }
    }

    override public func environmentFromSpec(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [(String, String)] {
        var env: [(String, String)] = super.environmentFromSpec(cbc, delegate, lookup: lookup)
        // The linker driver and linker may not be adjacent, so set PATH so the former can find the latter.
        env.append(("PATH", cbc.producer.executableSearchPaths.environmentRepresentation))
        return env
    }

    /// Compute the list of command line arguments and inputs to pass to the linker, given a list of library specifiers.
    ///
    /// Note that `inputs` will only contain values for libraries which are being directly linked by absolute path rather than by using search paths.
    private static func computeLibraryArgs(_ libraries: [LibrarySpecifier], scope: MacroEvaluationScope) -> (args: [String], inputs: [Path]) {
        // Construct the library arguments.
        return libraries.compactMap { specifier -> (args: [String], inputs: [Path]) in
            let basename = specifier.path.basename

            // FIXME: This isn't a good system, we need to redesign how we talk to the linker w.r.t. search paths and our notion of paths.
            switch specifier.kind {
            case .static:
                if specifier.useSearchPaths, basename.hasPrefix("lib"), basename.hasSuffix(".a") {
                    return (specifier.searchPathFlagsForLd(basename.withoutPrefix("lib").withoutSuffix(".a")), [])
                }
                return (specifier.absolutePathFlagsForLd(), [specifier.path])
            case .dynamic:
                let suffix = ".\(scope.evaluate(BuiltinMacros.DYNAMIC_LIBRARY_EXTENSION))"
                if specifier.useSearchPaths, basename.hasPrefix("lib"), basename.hasSuffix(suffix) {
                    return (specifier.searchPathFlagsForLd(basename.withoutPrefix("lib").withoutSuffix(suffix)), [])
                }
                return (specifier.absolutePathFlagsForLd(), [specifier.path])
            case .textBased:
                if specifier.useSearchPaths, basename.hasPrefix("lib"), basename.hasSuffix(".tbd") {
                    // .merge and .reexport are not supported for text-based libraries.
                    return (specifier.searchPathFlagsForLd(basename.withoutPrefix("lib").withoutSuffix(".tbd")), [])
                }
                return (specifier.absolutePathFlagsForLd(), [specifier.path])
            case .framework:
                let frameworkName = Path(basename).withoutSuffix
                if specifier.useSearchPaths {
                    return (specifier.searchPathFlagsForLd(frameworkName), [])
                }
                let absPathArgs = specifier.absolutePathFlagsForLd()
                let returnPath: Path
                if let pathArg = absPathArgs.last, Path(pathArg).basename == frameworkName {
                    returnPath = Path(pathArg)
                }
                else {
                    returnPath = specifier.path
                }
                return (absPathArgs, [returnPath])
            case .object:
                // Object files are added to linker inputs in the sources task producer.
                return ([], [])
            }
        }.reduce(([], [])) { (lhs, rhs) in (lhs.args + rhs.args, lhs.inputs + rhs.inputs) }
    }

    /// Find all linked frameworks and libraries from options in the values of the given macro names, and pass them back to be processed by the caller with the given blocks.
    /// - parameter macros: A list of `StringListMacroDeclaration` macros which will be evaluated to find the linker options. Defaults to a common list of such macros.
    /// - parameter settings: The `Settings` object whose scope will be used to evaluate `macro`.
    /// - parameter addFramework: A callback block which will be called when a framework option is found. The parameters to the block are the macro declaration, the linker option found, and the framework stem.
    /// - parameter addLibrary: A callback block which will be called when a library option is found. The parameters to the block are the macro declaration, the linker option found, and the library stem (excluding the leading `lib` and the suffix).
    /// - parameter addError: A callback block which will be called when an error in processing the macro's value is found, with an error reason parameter.
    public static func processLinkerSettingsForLibraryOptions(in macros: [StringListMacroDeclaration] = [BuiltinMacros.OTHER_LDFLAGS, BuiltinMacros.PRODUCT_SPECIFIC_LDFLAGS], settings: Settings, addFramework: @Sendable (StringListMacroDeclaration, String, String) async -> Void, addLibrary: @Sendable (StringListMacroDeclaration, String, String) async -> Void, addError: @Sendable (String) async -> Void) async {
        struct StaticVars {
            static let frameworkArgs = ["-framework", "-weak_framework", "-reexport_framework", "-merge_framework", "-no_merge_framework", "-lazy_framework", "-upward_framework"]
            // FIXME: Handle the _library options, and also the case of normal linkage where there is no option passed, just an absolute path
            // We're checking flags in this order, and there's an ambiguity between -l and -lazy-l because of the common prefix, so we need to make sure that -lazy-l goes first
            static let libPrefixArgs = ["-weak-l", "-merge-l", "-no_merge-l", "-reexport-l", "-lazy-l", "-upward-l", "-l"]
        }

        // TODO: We could use something like the LibrarySpecifier struct to pass back something other than a literal string as the linker option, but it requires some more thought as the LibrarySpecifier as-is isn't really designed for this sort of use.

        for macro in macros {
            let value = settings.globalScope.evaluate(macro)
            var argsIterator = value.makeIterator()
            // If we break out of this loop we've found an invalid set of options which we can't easily recover from.
            while let arg = argsIterator.next() {
                // Handle -Wl, in all its ugly glory.
                if arg.hasPrefix("-Wl,") {
                    // The annoying thing here is for framework options we could have "-Wl,<option>,<argument>" or "-Wl,<option> -Wl,<argument>".
                    let (option, argument): (String?, String?) = {
                        let components = arg.split(separator: ",")
                        if components.count == 1 {
                            return (nil, nil)
                        }
                        else if components.count == 2 {
                            return (String(components[1]), nil)
                        }
                        else {
                            // Not sure what it means if we end up with more components than the option supports, so we just ignore that.
                            return (String(components[1]), String(components[2]))
                        }
                    }()
                    guard let option else {
                        await addError("\(macro.name) in target '\(settings.target?.name ?? "<unknown>")': Found a standalone -Wl, argument")
                        continue
                    }
                    if StaticVars.frameworkArgs.contains(option) {
                        if let argument {
                            await addFramework(macro, option, argument)
                        }
                        else {
                            // See if the next option is also a -Wl,
                            guard let next = argsIterator.next() else {
                                await addError("\(macro.name) in target '\(settings.target?.name ?? "<unknown>")': Expected a framework name quoted with -Wl, after \(option)")
                                break
                            }
                            if next.hasPrefix("-Wl,") {
                                let argument: String? = {
                                    let components = next.split(separator: ",")
                                    if components.count == 1 {
                                        return nil
                                    }
                                    else {
                                        return String(components[1])
                                    }
                                }()
                                guard let argument else {
                                    await addError("\(macro.name) in target '\(settings.target?.name ?? "<unknown>")': Found a standalone -Wl, argument")
                                    continue
                                }
                                await addFramework(macro, option, argument)
                            }
                            else {
                                await addError("\(macro.name) in target '\(settings.target?.name ?? "<unknown>")': Expected a framework name quoted with -Wl, after \(option) but found '\(next)'")
                                break
                            }
                        }
                    }
                    else if let prefix = (StaticVars.libPrefixArgs.first { option.hasPrefix($0) }) {
                        let stem = String(option.dropFirst(prefix.count))
                        await addLibrary(macro, prefix, stem)
                    }
                }

                // Handle -Xlinker
                let isXlinker = (arg == "-Xlinker")
                guard let arg = isXlinker ? argsIterator.next() : arg else {
                    continue
                }

                if StaticVars.frameworkArgs.contains(arg) {
                    guard let next = argsIterator.next() else {
                        await addError("\(macro.name) in target '\(settings.target?.name ?? "<unknown>")': Expected a framework name after \(arg)")
                        break
                    }
                    let argument: String
                    if isXlinker && next == "-Xlinker" {
                        guard let next = argsIterator.next() else {
                            await addError("\(macro.name) in target '\(settings.target?.name ?? "<unknown>")': Expected a framework name quoted with -Xlinker after \(arg)")
                            break
                        }
                        argument  = next
                    }
                    else {
                        argument = next
                    }
                    await addFramework(macro, arg, argument)
                }
                else if let prefix = (StaticVars.libPrefixArgs.first { arg.hasPrefix($0) }) {
                    let stem = String(arg.dropFirst(prefix.count))
                    await addLibrary(macro, prefix, stem)
                }
            }
        }
    }

    override public var payloadType: (any TaskPayload.Type)? { return LdLinkerTaskPayload.self }

    override public func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return LdLinkerOutputParser.self
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        // The ALTERNATE_LINKER is the 'name' of the linker not the executable name, clang will find the linker binary based on name passed via -fuse-ld, but we need to discover
        // its properties by executing the actual binary. There is a common filename when the linker is not "ld" across all platforms using "ld.<ALTERNAME_LINKER>(.exe)"
        // macOS (Xcode SDK)
        // -----------------
        // ld
        // ld-classic
        //
        // macOS (Open Source)
        // -----------
        // ld.lld -> lld
        // ld64.lld -> lld
        // lld
        // lld-link -> lld
        //
        // Linux
        // ------
        // /usr/bin/ld -> aarch64-linux-gnu-ld
        // /usr/bin/ld.bfd -> aarch64-linux-gnu-ld.bfd
        // /usr/bin/ld.gold -> aarch64-linux-gnu-ld.gold
        // /usr/bin/ld.lld -> lld
        // /usr/bin/ld64.lld -> lld
        // /usr/bin/lld
        // /usr/bin/lld-link -> lld
        // /usr/bin/gold -> aarch64-linux-gnu-gold
        //
        // Windows
        // -------
        // ld.lld.exe
        // ld64.lld.exe
        // lld-link.exe
        // lld.exe
        // link.exe //In Visual Studio
        //
        // Note: On Linux you cannot invoke the llvm linker by the direct name for determining the version,
        // you need to use ld.<ALTERNATE_LINKER>
        let alternateLinker = scope.evaluate(BuiltinMacros.ALTERNATE_LINKER)
        let isLinkerMultiarch = scope.evaluate(BuiltinMacros._LD_MULTIARCH)

        var linkerPath = producer.hostOperatingSystem == .windows ? Path("ld.lld") : Path("ld")
        if alternateLinker != "" && alternateLinker != "ld" && alternateLinker != "link" {
            linkerPath = Path(producer.hostOperatingSystem.imageFormat.executableName(basename: "ld.\(alternateLinker)"))
        } else if alternateLinker != "" {
            linkerPath =  Path(alternateLinker)
        }
        // If the linker does not support multiple architectures update the path to include a subfolder based on the prefix map
        // to find the architecture specific executable.
        if !isLinkerMultiarch {
            let archMap = scope.evaluate(BuiltinMacros._LD_MULTIARCH_PREFIX_MAP)
            let archMappings = archMap.reduce(into: [String: String]()) { mappings, map in
                let (arch, prefixDir) = map.split(":")
                if !arch.isEmpty && !prefixDir.isEmpty {
                    return mappings[arch] = prefixDir
                }
            }
            if archMappings.isEmpty {
                delegate.error("_LD_MULTIARCH is 'false', but no prefix mappings are present in _LD_MULTIARCH_PREFIX_MAP")
                return nil
            }
            // Linkers that don't support multiple architectures cannot support universal binaries, so ARCHS will
            // contain the target architecture and can only be a single value.
            guard let arch = scope.evaluate(BuiltinMacros.ARCHS).only else {
                delegate.error("_LD_MULTIARCH is 'false', but multiple ARCHS have been given, this is invalid")
                return nil
            }
            if let prefix = archMappings[arch] {
                // Add in the target architecture prefix directory to path for search.
                linkerPath = Path(prefix).join(linkerPath)
            } else {
                delegate.error("Could not find prefix mapping for \(arch) in _LD_MULTIARCH_PREFIX_MAP")
                return nil
            }
        }
        guard let toolPath = producer.executableSearchPaths.findExecutable(operatingSystem: producer.hostOperatingSystem, basename: linkerPath.str) else {
            return nil
        }
        // Create the cache key.  This is just the path to the linker we would invoke if we were invoking the linker directly.
        return await discoveredLinkerToolsInfo(producer, delegate, at: toolPath)
    }
}

/// Extensions to `LinkerSpec.LibrarySpecifier` specific to the dynamic linker.
fileprivate extension LinkerSpec.LibrarySpecifier {
    func searchPathFlagsForLd(_ name: String) -> [String] {
        switch (kind, mode) {
        case (.dynamic, .normal):
            return ["-l" + name]
        case (.dynamic, .reexport):
            return ["-Xlinker", "-reexport-l" + name]
        case (.dynamic, .merge):
            return ["-Xlinker", "-merge-l" + name]
        case (.dynamic, .reexport_merge):
            return ["-Xlinker", "-no_merge-l" + name]
        case (.dynamic, .weak):
            return ["-weak-l" + name]
        case (.static, .weak),
             (.textBased, .weak):
            return ["-weak-l" + name]
        case (.static, _),
             (.textBased, _):
            // Other modes are not supported for these kinds.
            return ["-l" + name]
        case (.framework, .normal):
            return ["-framework", name]
        case (.framework, .reexport):
            return ["-Xlinker", "-reexport_framework", "-Xlinker", name]
        case (.framework, .merge):
            return ["-Xlinker", "-merge_framework", "-Xlinker", name]
        case (.framework, .reexport_merge):
            return ["-Xlinker", "-no_merge_framework", "-Xlinker", name]
        case (.framework, .weak):
            return ["-weak_framework", name]
        case (.object, _):
            // Object files are added to linker inputs in the sources task producer.
            return []
        }
    }

    func absolutePathFlagsForLd() -> [String] {
        switch (kind, mode) {
        case (.dynamic, .normal):
            return [path.str]
        case (.dynamic, .reexport):
            return ["-Xlinker", "-reexport_library", "-Xlinker", path.str]
        case (.dynamic, .merge):
            return ["-Xlinker", "-merge_library", "-Xlinker", path.str]
        case (.dynamic, .reexport_merge):
            return ["-Xlinker", "-no_merge_library", "-Xlinker", path.str]
        case (.dynamic, .weak):
            return ["-weak_library", path.str]
        case (.static, .weak),
             (.textBased, .weak):
            return ["-weak_library", path.str]
        case (.static, _),
             (.textBased, _):
            // Other modes are not supported for these kinds.
            return [path.str]
        // FIXME: When linking with absolute paths, we pass the path to library inside the framework using the appropriate -***_library option (or no option for normal mode). This is probably a mis-feature, I doubt it is a good idea to bypass the linker's notion of frameworkness, but this has been the behavior for a long time and it's not clear that the linker provides us with a better alternative.
        case (.framework, .normal):
            return [path.join(Path(path.basename).withoutSuffix).str]
        case (.framework, .reexport):
            return ["-Xlinker", "-reexport_library", "-Xlinker", path.join(Path(path.basename).withoutSuffix).str]
        case (.framework, .merge):
            return ["-Xlinker", "-merge_library", "-Xlinker", path.join(Path(path.basename).withoutSuffix).str]
        case (.framework, .reexport_merge):
            return ["-Xlinker", "-no_merge_library", "-Xlinker", path.join(Path(path.basename).withoutSuffix).str]
        case (.framework, .weak):
            return ["-weak_library", path.join(Path(path.basename).withoutSuffix).str]
        case (.object, _):
            // Object files are added to linker inputs in the sources task producer.
            return []
        }
    }
}

public struct DiscoveredLibtoolLinkerToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public let toolVersion: Version?
}

public final class LibtoolLinkerSpec : GenericLinkerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.pbx.linkers.libtool"

    override public var payloadType: (any TaskPayload.Type)? { return LibtoolLinkerTaskPayload.self }

    public func libtoolToolPath(_ cbc: CommandBuildContext) -> Path {
        return libtoolToolPath(cbc.producer, cbc.scope)
    }

    public func libtoolToolPath(_ producer: any CommandProducer, _ scope: MacroEvaluationScope) -> Path {
        let lookupPath = scope.evaluate(BuiltinMacros.LIBTOOL).nilIfEmpty ?? Path("libtool")
        return resolveExecutablePath(producer, lookupPath)
    }

    static func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, toolPath: Path) async throws -> DiscoveredLibtoolLinkerToolSpecInfo {
        if toolPath.basenameWithoutSuffix == "llvm-lib" || toolPath.basenameWithoutSuffix == "ar" || toolPath.basenameWithoutSuffix.hasSuffix("-ar") {
            return DiscoveredLibtoolLinkerToolSpecInfo(toolPath: toolPath, toolVersion: nil)
        }

        return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, [toolPath.str, producer.isApplePlatform ? "-V" : "--version"], { executionResult in
            let outputString = String(decoding: executionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let regexes: [Regex<(Substring, libtool: Substring)>]
            if producer.isApplePlatform {
                regexes = [#/^Apple Inc\. version cctools(?:_[A-Za-z0-9_]+)?-(?<libtool>[0-9\.]+)$/#]
            } else {
                regexes = [
                    #/^libtool \(GNU libtool\) (?<libtool>[0-9\.]+).*/#,
                    #/^LLD (?<libtool>[0-9\.]+).*/#,
                ]
            }
            guard let match = try regexes.compactMap({ try $0.firstMatch(in: outputString) }).first else {
                throw StubError.error("Could not parse libtool version from: \(outputString)")
            }

            return try DiscoveredLibtoolLinkerToolSpecInfo(toolPath: toolPath, toolVersion: Version(String(match.output.libtool)))
        })
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await Self.discoveredCommandLineToolSpecInfo(producer, delegate, toolPath: libtoolToolPath(producer, scope))
        } catch {
            delegate.error(error)
            return nil
        }
    }

    override public func constructLinkerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, libraries: [LibrarySpecifier], usedTools: [CommandLineToolSpec: Set<FileTypeSpec>]) async {
        var inputPaths = cbc.inputs.map({ $0.absolutePath })
        var specialArgs = [String]()

        if cbc.scope.evaluate(BuiltinMacros.LIBTOOL_USE_RESPONSE_FILE) {
            // Define the linker file list.
            let fileListPath = cbc.scope.evaluate(BuiltinMacros.__INPUT_FILE_LIST_PATH__)
            if !fileListPath.isEmpty {
                let contents = cbc.inputs.map({ return $0.absolutePath.strWithPosixSlashes + "\n" }).joined(separator: "")
                cbc.producer.writeFileSpec.constructFileTasks(CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: [], output: fileListPath), delegate, contents: ByteString(encodingAsUTF8: contents), permissions: nil, preparesForIndexing: false, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                inputPaths.append(fileListPath)
            }
        } else {
            specialArgs.append(contentsOf: cbc.inputs.map { $0.absolutePath.str })
            inputPaths.append(contentsOf: cbc.inputs.map { $0.absolutePath })
        }

        // Add arguments for the contents of the Link Binaries build phase.
        specialArgs.append(contentsOf: libraries.flatMap { specifier -> [String] in
            let basename = specifier.path.basename

            switch specifier.kind {
            case .static:
                // A static library can build against another static library.

                // If directed to link it weakly, we emit a warning, since libtool can't perform weak linking (since it's not really linking).  Then we pass it normally.
                // We silently ignore other non-normal modes, since they are only set programmatically and there's nothing the user can do about them.
                if specifier.mode == .weak {
                    delegate.warning("Product \(cbc.output.basename) cannot weak-link \(specifier.kind) \(basename)")
                }

                if specifier.useSearchPaths, basename.hasPrefix("lib"), basename.hasSuffix(".a") {
                    // Locate using search paths: Add a -l option and *don't* add the path to the library as an input to the task.
                    return ["-l" + basename.withoutPrefix("lib").withoutSuffix(".a")]
                }
                else {
                    // Locate using an absolute path: Add the path as an option and as an input to the task.
                    inputPaths.append(specifier.path)
                    return [specifier.path.str]
                }

            case .object:
                // Object files are added to linker inputs in the sources task producer and so end up in the link-file-list.
                return []

            case .framework:
                // A static library can build against a framework, since the library in the framework could be a static library, which is valid, and we can't tell here whether it is or not.  So we leave it to libtool to do the right thing here.
                // Also, we wouldn't want to emit an error here even if we could determine that it contained a dylib, since the target might be only using the framework to find headers.

                // If directed to link it weakly, we emit a warning, since libtool can't perform weak linking (since it's not really linking).  Then we pass it normally.
                // We silently ignore other non-normal modes, since they are only set programmatically and there's nothing the user can do about them.
                if specifier.mode == .weak {
                    delegate.warning("Product \(cbc.output.basename) cannot weak-link \(specifier.kind) \(basename)")
                }

                let frameworkName = Path(basename).withoutSuffix
                if specifier.useSearchPaths {
                    return ["-framework", frameworkName]
                } else {
                    // If we aren't using search paths, we point to the library inside the framework.
                    //
                    // FIXME: This is probably a mis-feature, I doubt it is a good idea to bypass the linker's notion of frameworkness.
                    let frameworkLibraryPath = specifier.path.join(frameworkName)
                    return [frameworkLibraryPath.str]
                }

            case .dynamic, .textBased:
                // A static library can't build against a dynamic library, or against a .tbd file, so we don't add any arguments here.  But the inclusion of such a file in the Link Binaries build phase might be used to find implicit dependencies.
                // We don't have a concrete example of this, and we used to emit an error here, but we removed it in <rdar://problem/34314195>.
                return []
            }
        })

        var outputs: [any PlannedNode] = [delegate.createNode(cbc.output)] + cbc.commandOrderingOutputs

        // Add flags to emit dependency info.
        var dependencyInfo: DependencyDataStyle?
        let dependencyInfoFile = cbc.scope.evaluate(BuiltinMacros.LIBTOOL_DEPENDENCY_INFO_FILE)
        if !dependencyInfoFile.isEmpty {
            specialArgs += ["-dependency_info", dependencyInfoFile.str]
            dependencyInfo = .dependencyInfo(dependencyInfoFile)
            outputs.append(delegate.createNode(dependencyInfoFile))
        }

        let optionContext = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)

        // Generate the command line.
        let commandLine = commandLineFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs).map(\.asString)

        // Compute the inputs and outputs.
        var inputs = inputPaths.map{ delegate.createNode($0) }
        // Add inputs for the (un)exports files, if we generated options for them.
        if let idx = commandLine.firstIndex(of: "-exported_symbols_list"), idx+1 < commandLine.count {
            inputs.append(delegate.createNode(Path(commandLine[idx+1]).normalize()))
        }
        if let idx = commandLine.firstIndex(of: "-unexported_symbols_list"), idx+1 < commandLine.count {
            inputs.append(delegate.createNode(Path(commandLine[idx+1]).normalize()))
        }

        var payload: LibtoolLinkerTaskPayload? = nil
        if dependencyInfo != nil {
            let architecture = cbc.scope.evaluate(BuiltinMacros.arch)
            let buildVariant = cbc.scope.evaluate(BuiltinMacros.variant)
            let objectFileDir = cbc.scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR)
            let previewPayload = LdLinkerTaskPreviewPayload(
                architecture: architecture,
                buildVariant: buildVariant,
                objectFileDir: objectFileDir,
                linkStyle: .staticLib
            )

            // Silently fix up the dependency info in order to avoid generating incorrect dependencies in certain
            // cases:
            // <rdar://58021911> linking against symlinks prevents proper discovered dependency resolution
            let editPayload = DependencyInfoEditPayload(
                removablePaths: [],
                removableBasenames: [],
                developerPath: cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR)
            )
            payload = LibtoolLinkerTaskPayload(
                dependencyInfoEditPayload: editPayload,
                previewPayload: previewPayload
            )
        }

        // Create the task.
        delegate.createTask(
            type: self,
            dependencyData: dependencyInfo,
            payload: payload,
            ruleInfo: defaultRuleInfo(cbc, delegate),
            commandLine: commandLine,
            environment: environmentFromSpec(cbc, delegate),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs,
            outputs: outputs,
            action: nil,
            execDescription: resolveExecutionDescription(cbc, delegate),
            enableSandboxing: enableSandboxing
        )
    }

    public override func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        switch input {
        case .thunkInfo:
            return []
        case .targetDependencyInfo:
            return generateTargetDependencyPreviewInfo(for: task)
        }
    }

    private func generateTargetDependencyPreviewInfo(for task: any ExecutableTask) -> [TaskGeneratePreviewInfoOutput] {
        guard let payload = task.payload as? LibtoolLinkerTaskPayload else { return [] }
        guard let previewPayload = payload.previewPayload else { return [] }

        return [
            TaskGeneratePreviewInfoOutput(
                architecture: previewPayload.architecture,
                buildVariant: previewPayload.buildVariant,
                commandLine: Array(task.commandLineAsStrings),
                workingDirectory: task.workingDirectory,
                input: Path(""),
                output: Path(""),
                type: .Ld
            )
        ]
    }
}

/// Consults the global cache of discovered info for the linker at `toolPath` and returns it, creating it if necessary.
///
/// This is global and public because it is used by `SWBTaskExecution` and `CoreBasedTests`, which is the basis of many of our tests (so caching this info across tests is desirable).
public func discoveredLinkerToolsInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path) async -> (any DiscoveredCommandLineToolSpecInfo)? {
    do {
        do {
            let commandLine = [toolPath.str, "-version_details"]
            return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, commandLine, { executionResult in
                let gnuLD = [
                    #/GNU ld version (?<version>[\d.]+)-.*/#,
                    #/GNU ld \(GNU Binutils.*\) (?<version>[\d.]+)/#,
                ]
                if let match = try gnuLD.compactMap({ try $0.firstMatch(in: String(decoding: executionResult.stdout, as: UTF8.self)) }).first {
                    return DiscoveredLdLinkerToolSpecInfo(linker: .gnuld, toolPath: toolPath, toolVersion: try Version(String(match.output.version)), architectures: Set())
                }

                let goLD = [
                    #/GNU gold version (?<version>[\d.]+)-.*/#,
                    #/GNU gold \(GNU Binutils.*\) (?<version>[\d.]+)/#, // Ubuntu "GNU gold (GNU Binutils for Ubuntu 2.38) 1.16", Debian "GNU gold (GNU Binutils for Debian 2.40) 1.16"
                    #/GNU gold \(version .*\) (?<version>[\d.]+)/#,     // Fedora "GNU gold (version 2.40-14.fc39) 1.16", RHEL "GNU gold (version 2.35.2-54.el9) 1.16", Amazon "GNU gold (version 2.29.1-31.amzn2.0.1) 1.14"
                ]

                if let match = try goLD.compactMap({ try $0.firstMatch(in: String(decoding: executionResult.stdout, as: UTF8.self)) }).first {
                    return DiscoveredLdLinkerToolSpecInfo(linker: .gold, toolPath: toolPath, toolVersion: try Version(String(match.output.version)), architectures: Set())
                }

                // link.exe has no option to simply dump the version, running, the program will no arguments or an invalid one will dump a header that contains the version.
                let linkExe = [
                    #/Microsoft \(R\) Incremental Linker Version (?<version>[\d.]+)/#
                ]
                if let match = try linkExe.compactMap({ try $0.firstMatch(in: String(decoding: executionResult.stdout, as: UTF8.self)) }).first {
                    return DiscoveredLdLinkerToolSpecInfo(linker: .linkExe, toolPath: toolPath, toolVersion: try Version(String(match.output.version)), architectures: Set())
                }

                struct LDVersionDetails: Decodable {
                    let version: Version
                    let architectures: Set<String>
                }

                let details: LDVersionDetails
                do {
                    details = try JSONDecoder().decode(LDVersionDetails.self, from: executionResult.stdout)
                } catch {
                    throw CommandLineOutputJSONParsingError(commandLine: commandLine, data: executionResult.stdout)
                }

                return DiscoveredLdLinkerToolSpecInfo(linker: .ld64, toolPath: toolPath, toolVersion: details.version, architectures: details.architectures)
            })
        } catch let e as CommandLineOutputJSONParsingError {
            let vCommandLine = [toolPath.str, "-v"]
            return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, vCommandLine, { executionResult in
                let lld = [
                    #/LLD (?<version>[\d.]+).*/#,
                ]
                if let match = try lld.compactMap({ try $0.firstMatch(in: String(decoding: executionResult.stdout, as: UTF8.self)) }).first {
                    return DiscoveredLdLinkerToolSpecInfo(linker: .lld, toolPath: toolPath, toolVersion: try Version(String(match.output.version)), architectures: Set())
                }

                let versionCommandLine = [toolPath.str, "--version"]
                return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, versionCommandLine, { executionResult in
                    let lld = [
                        #/LLD (?<version>[\d.]+).*/#,
                    ]
                    if let match = try lld.compactMap({ try $0.firstMatch(in: String(decoding: executionResult.stdout, as: UTF8.self)) }).first {
                        return DiscoveredLdLinkerToolSpecInfo(linker: .lld, toolPath: toolPath, toolVersion: try Version(String(match.output.version)), architectures: Set())
                    }

                    throw e
                })
            })
        }
    } catch {
        delegate.error(error)
        return nil
    }
}

/// Enumerates a linker command line, calling the provided `handle` closure for each logical argument, providing the argument name as `arg` and a `value` function which returns the value of that argument at `offset` positions distance from the `arg` value based on how many arguments it takes.
///
/// The purpose of this function is to automatically abstract away handling of the `-Xlinker` and `-Wl` syntax used by compiler drivers to forward arguments to the linker which they themselves do not understand.
fileprivate func enumerateLinkerCommandLine(arguments: [String], handleWl: Bool = true, _ handle: (_ arg: String, _ value: (_ offset: Int) -> String?) -> Void) {
    var arguments = arguments
    if handleWl {
        arguments = arguments.flatMap { arg -> [String] in
            let wlPrefix = "-Wl,"
            if arg.hasPrefix(wlPrefix) {
                return arg.withoutPrefix(wlPrefix).split(separator: ",").flatMap { ["-Xlinker", String($0)] }
            } else {
                return [arg]
            }
        }
    }
    var it = arguments.makeIterator()
    while let arg = it.next() {
        let isXlinker = arg == "-Xlinker"
        guard let arg = isXlinker ? it.next() : arg else {
            continue
        }

        handle(arg, { (offset: Int) -> String? in
            // The driver accepts both `-Xlinker -flag value` _and_ `-Xlinker -flag -Xlinker value`.
            // So if the first argument used -Xlinker, we may or may not have more.
            if let value = it.next(count: offset, transform: { it, arg in isXlinker && arg == "-Xlinker" ? it.next() : arg }).last ?? nil {
                return value
            }
            return nil
        })
    }
}

fileprivate func filterLinkerFlagsWhenUnderPreviewsDylib(_ flags: [String]) -> [String] {
    var newFlags: [String] = []
    var it = flags.makeIterator()
    while let flag = it.next() {
        if flag.hasPrefix("-Wl,-dyld_env,") {
            continue
        }
        if flag == "-dyld_env" && newFlags.last == "-Xlinker" {
            // Filter out -dyld_env when using the previews dylib, since the linker only
            // accepts this flag when linking a main executable.
            // This is a convenience to allow users to transition from OTHER_LDFLAGS to the
            // dedicated LD_ENVIRONMENT setting (by defining both at once) in order to remain
            // compatible with Xcode versions both before and after this change.
            newFlags.removeLast()
            while let next = it.next() {
                if next != "-Xlinker" {
                    break
                }
            }
            continue
        }
        else if flag == "-client_name" {
            // Filter out `-client_Name` when using the previews dylib, since this isn't
            // allowed on dylibs. Transition from `OTHER_LD_FLAGS` to the dedicated
            // `LD_CLIENT_NAME` (by defining both at once) in order to remain compatible with
            // Xcode versions both before and after this change.
            if newFlags.last == "-Xlinker" {
                // -Xlinker is optional for -client_name so we need to handle both it's presence
                // and absence for both arguments.
                newFlags.removeLast()
                while let next = it.next() {
                    if next != "-Xlinker" {
                        break
                    }
                }
            }
            else {
                _ = it.next()
            }
            continue
        }
        newFlags.append(flag)
    }
    return newFlags
}
