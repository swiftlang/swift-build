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

public final class SwiftABIGenerationToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, SwiftDiscoveredCommandLineToolSpecInfo, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.swift-abi-generation"

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await (self as (any SwiftDiscoveredCommandLineToolSpecInfo)).discoveredCommandLineToolSpecInfo(producer, scope, delegate)
        } catch {
            delegate.error(error)
            return nil
        }
    }

    override public func resolveExecutablePath(_ cbc: CommandBuildContext, _ path: Path, delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> Path {
        let swiftInfo = await cbc.producer.swiftCompilerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        if let prospectivePath = swiftInfo?.toolPath.dirname.join(path), cbc.producer.executableSearchPaths.fs.exists(prospectivePath) {
            return prospectivePath
        }

        return await super.resolveExecutablePath(cbc, path, delegate: delegate)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }
    public func constructABIGenerationTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ baselineFile: Path) async {
        let toolSpecInfo: DiscoveredSwiftCompilerToolSpecInfo
        do {
            toolSpecInfo = try await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        } catch {
            delegate.error("Unable to discover `swiftc` command line tool info: \(error)")
            return
        }

        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        commandLine += ["-o", baselineFile.normalize().str]
        commandLine.append(contentsOf: computeSharedAPIDigesterFlags(cbc: cbc, toolSpecInfo: toolSpecInfo))
        delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: cbc.inputs.map { delegate.createNode($0.absolutePath) },
                            outputs: [delegate.createNode(cbc.output)],
                            enableSandboxing: enableSandboxing)
    }
}

func computeSharedAPIDigesterFlags(cbc: CommandBuildContext, toolSpecInfo: DiscoveredSwiftCompilerToolSpecInfo) -> [String] {
    var commandLine: [String] = []
    for searchPath in SwiftCompilerSpec.collectInputSearchPaths(cbc, toolInfo: toolSpecInfo) {
        commandLine += ["-I", searchPath]
    }
    let supportsCxxInterop = toolSpecInfo.toolFeatures.has(.apiDigesterCxxInterop)
    let swiftCompilerArguments = supportsCxxInterop ? cbc.producer.swiftCompilerSpec.commandLineFromOptions(cbc.producer, scope: cbc.scope, inputFileType: nil, optionContext: toolSpecInfo, buildOptionsFilter: .all).map(\.asString) : []
    if toolSpecInfo.toolFeatures.has(.apiDigesterXcc) {
        // Older digesters reject C++ arguments such as -std, so they only get those in OTHER_SWIFT_FLAGS.
        let arguments = supportsCxxInterop ? swiftCompilerArguments : cbc.scope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS)
        for (index, argument) in arguments.enumerated().dropLast() where argument == "-Xcc" {
            commandLine.append(contentsOf: ["-Xcc", arguments[index + 1]])
        }
        let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, cbc.scope, usesModules: true, forSwift: true)
        let commonHeaderSearchArgs = headerSearchPaths.searchPathArguments(for: cbc.producer.swiftCompilerSpec, scope: cbc.scope)
        for option in commonHeaderSearchArgs {
            commandLine.append(contentsOf: ["-Xcc", option])
        }
        for cppDefinition in cbc.scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS) {
            // FIXME: Separate -D and its argument.
            commandLine.append(contentsOf: ["-Xcc", "-D" + cppDefinition])
        }
    }
    if supportsCxxInterop, let flag = swiftCompilerArguments.last(where: { $0.hasPrefix("-cxx-interoperability-mode=") }) {
        commandLine.append(flag)
    }
    return commandLine
}
