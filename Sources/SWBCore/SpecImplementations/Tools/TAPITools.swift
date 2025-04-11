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

public struct DiscoveredTAPIToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public let toolVersion: Version?
}

public final class TAPIToolSpec : GenericCommandLineToolSpec, GCCCompatibleCompilerCommandLineBuilder, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.tapi.installapi"

    public static let dSYMSupportRequiredVersion = try! FuzzyVersion("1500.*.7")

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        return cbc.scope.tapiExecutablePath()
    }

    public override func resolveExecutablePath(_ cbc: CommandBuildContext, _ path: Path) -> Path {
        // Ignore "tapi" from the spec and go through TAPI_EXEC
        // FIXME: We should go through the normal spec mechanisms...
        return resolveExecutablePath(cbc.producer, Path(computeExecutablePath(cbc)))
    }

    // FIXME: Ideally this would just go in the spec itself
    public override func commandLineFromOptions(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, optionContext: (any BuildOptionGenerationContext)?, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        let innerLookup: ((MacroDeclaration) -> MacroExpression?) = { macro in
            switch macro {
            case BuiltinMacros.TAPI_HEADER_SEARCH_PATHS:
                let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, cbc.scope, usesModules: cbc.scope.evaluate(BuiltinMacros.TAPI_ENABLE_MODULES))
                let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(cbc.producer, cbc.scope)
                let sparseSDKSearchPaths = GCCCompatibleCompilerSpecSupport.sparseSDKSearchPathArguments(cbc.producer.sparseSDKs, headerSearchPaths.headerSearchPaths, frameworkSearchPaths.frameworkSearchPaths)

                let defaultHeaderSearchPaths = headerSearchPaths.searchPathArguments(for:self, scope:cbc.scope)

                let userHeaderSearchPaths = cbc.scope.evaluate(BuiltinMacros.TAPI_HEADER_SEARCH_PATHS, lookup: lookup).map {
                    return "-I" + $0
                }
                let defaultFrameworkSearchPaths = frameworkSearchPaths.searchPathArguments(for: self, scope:cbc.scope) + sparseSDKSearchPaths.searchPathArguments(for:self, scope:cbc.scope)

                return cbc.scope.namespace.parseLiteralStringList(defaultHeaderSearchPaths + userHeaderSearchPaths + defaultFrameworkSearchPaths)

            default:
                return lookup?(macro)
            }
        }

        // TAPI's SRCROOT support is required to enable project header parsing.
        let requiresSRCROOTSupport = cbc.scope.evaluate(BuiltinMacros.TAPI_ENABLE_PROJECT_HEADERS) || cbc.scope.evaluate(BuiltinMacros.TAPI_USE_SRCROOT)

        let tapiFileListArgs: [CommandLineArgument] = ["-filelist", .path(Path(cbc.scope.evaluate(BuiltinMacros.TapiFileListPath, lookup: lookup)))]

        return super.commandLineFromOptions(cbc, delegate, optionContext: optionContext, lookup: requiresSRCROOTSupport ? innerLookup : lookup) + tapiFileListArgs
    }

    /// Construct a new task to run the TAPI tool.
    public func constructTAPITasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, generatedTBDFiles: [Path], builtBinaryPath: Path? = nil, fileListPath: Path? = nil, dsymPath: Path? = nil) async {
        let scope = cbc.scope
        let useOnlyFilelist = scope.evaluate(BuiltinMacros.TAPI_ENABLE_PROJECT_HEADERS) || scope.evaluate(BuiltinMacros.TAPI_USE_SRCROOT)

        let runpathSearchPaths = await LdLinkerSpec.computeRPaths(cbc, delegate, inputRunpathSearchPaths: scope.evaluate(BuiltinMacros.TAPI_RUNPATH_SEARCH_PATHS), isUsingSwift: !generatedTBDFiles.isEmpty)
        let runpathSearchPathsExpr = scope.namespace.parseStringList(runpathSearchPaths)

        // Create a lookup closure for build setting overrides.
        let lookup: ((MacroDeclaration) -> MacroExpression?) = { macro in
            switch macro {
            case BuiltinMacros.TAPI_INPUTS:
                return useOnlyFilelist ? nil : scope.namespace.parseLiteralStringList(cbc.inputs.map{ $0.absolutePath.str })

            case BuiltinMacros.BuiltBinaryPath:
                return scope.namespace.parseLiteralString(builtBinaryPath?.normalize().str ?? "")

            case BuiltinMacros.TapiFileListPath:
                return scope.namespace.parseLiteralString(fileListPath?.normalize().str ?? "")

            case BuiltinMacros.TAPI_RUNPATH_SEARCH_PATHS:
                return runpathSearchPathsExpr

            default:
                return nil
            }
        }

        // Compute the rule info.
        let ruleInfo: [String] = defaultRuleInfo(cbc, delegate, lookup: lookup)

        let toolInfo = await discoveredCommandLineToolSpecInfo(cbc.producer, scope, delegate)

        // Compute the command line.
        var commandLine: [String] = commandLineFromTemplate(cbc, delegate, optionContext: toolInfo, lookup: lookup).map(\.asString)

        // Compute inputs.
        var inputs = cbc.inputs.map({ delegate.createNode($0.absolutePath) }) as [PlannedPathNode]
        + (fileListPath.flatMap({ [delegate.createNode($0)] }) ?? []) as [PlannedPathNode]
        + generatedTBDFiles.map({ delegate.createNode($0) }) as [PlannedPathNode]
            + cbc.commandOrderingInputs

        // Compute swift aware arguments for installapi consumption and verification.
        // We can infer requested swift support within tapi from the generatedTBDFiles container,
        // which is the only time we should ignore the swift generated header.
        // This check can be removed once older tapi versions don't need to be supported.
        if !generatedTBDFiles.isEmpty {
            let producer = cbc.producer
            let swiftCompilerSpec = producer.swiftCompilerSpec
            let optionContext = await swiftCompilerSpec.discoveredCommandLineToolSpecInfo(producer, scope, delegate)
            commandLine += await swiftCompilerSpec.computeAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: [], optionContext: optionContext, forTAPI: true, delegate: delegate).args.flatMap({ $0 })

            if !scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME).isEmpty && scope.evaluate(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER) {
                let generatedHeaderPath = SwiftCompilerSpec.generatedObjectiveCHeaderOutputPath(scope).str
                commandLine.append(contentsOf: ["-exclude-public-header",
                                                generatedHeaderPath])
                inputs.append(delegate.createNode(Path(generatedHeaderPath)))
            }
        }
        for file in generatedTBDFiles {
            commandLine.append(contentsOf: ["-swift-installapi-interface", file.str])
        }

        inputs.append(contentsOf: (builtBinaryPath.flatMap({ [delegate.createNode($0)] }) ?? []) as [PlannedPathNode])

        inputs.append(contentsOf: (dsymPath.flatMap({ [delegate.createNode($0)] }) ?? []) as [PlannedPathNode])

        if let version = toolInfo?.toolVersion, version >= TAPIToolSpec.dSYMSupportRequiredVersion,
                dsymPath != nil, scope.evaluate(BuiltinMacros.TAPI_READ_DSYM) {
            let dsymBundle = scope.evaluate(BuiltinMacros.DWARF_DSYM_FOLDER_PATH)
                .join(scope.evaluate(BuiltinMacros.DWARF_DSYM_FILE_NAME))
            commandLine.append(contentsOf: ["--dsym=" + dsymBundle.str])
        }

        // Workaround for headermap limitation: rdar://92350575 (Invalid headermap entry for dylib installed headers)
        if !cbc.isFramework {
            commandLine.append(contentsOf: ["--product-name=" + scope.evaluate(BuiltinMacros.PRODUCT_NAME)])
        }

        let outputs: [any PlannedNode] = [delegate.createNode(cbc.output)] + cbc.commandOrderingOutputs
        delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate, lookup: lookup), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, action: nil, execDescription: resolveExecutionDescription(cbc, delegate, lookup: lookup), enableSandboxing: enableSandboxing)
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, Path(scope.tapiExecutablePath()))

        // Get the info from the global cache.
        do {
            return try await discoveredTAPIToolInfo(producer, delegate, at: toolPath)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

final class TAPIMergeToolSpec : CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    static let identifier = "com.apple.build-tools.tapi.merge"

    class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return TAPIMergeToolSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let outputPath = cbc.output

        // Compute the command arguments.
        //
        // FIXME: We don't have a spec to work with here, we should get one.
        var commandLine = [resolveExecutablePath(cbc.producer, Path(cbc.scope.tapiExecutablePath())).str]
        commandLine += ["archive", "--merge", "--allow-arch-merges"]
        commandLine += cbc.inputs.map{ $0.absolutePath.str }
        commandLine += ["-o", outputPath.str]

        let outputs: [any PlannedNode] = [delegate.createNode(outputPath)] + cbc.commandOrderingOutputs
        delegate.createTask(type: self, ruleInfo: ["MergeTAPI", outputPath.str], commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ delegate.createNode($0.absolutePath) }), outputs: outputs, action: nil, execDescription: "MergeTAPI " + outputPath.basename, enableSandboxing: enableSandboxing)
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, Path(scope.tapiExecutablePath()))

        // Get the info from the global cache.
        do {
            return try await discoveredTAPIToolInfo(producer, delegate, at: toolPath)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

public func discoveredTAPIToolInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path) async throws -> DiscoveredTAPIToolSpecInfo {
    return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, [toolPath.str, "--version"]) { executionResult in
        let outputString = String(decoding: executionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = try #/^Apple TAPI version.+\(tapi[_\w\d]*-(?<tapi>[\d.]+)\).*$/#.wholeMatch(in: outputString) else {
            throw StubError.error("Could not parse tapi version from: \(outputString)")
        }

        return try DiscoveredTAPIToolSpecInfo(toolPath: toolPath, toolVersion: Version(String(match.output.tapi)))
    }
}

extension MacroEvaluationScope {
    func tapiExecutablePath(lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        return evaluate(BuiltinMacros.TAPI_EXEC, lookup: lookup, default: "tapi").str
    }
}
