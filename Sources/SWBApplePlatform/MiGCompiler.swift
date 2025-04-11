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
public import SWBCore
public import SWBMacro
import SWBProtocol

public struct DiscoveredMiGToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public var toolVersion: Version?
}

public final class MigCompilerSpec : CompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.mig"

    required override init(_ parser: SpecParser, _ basedOnSpec: Spec?, isGeneric: Bool) {
        // In Xcode, this is a generic specification, but we customize it. Thus, we claim the generic parameters here to avoid spurious warnings.
        parser.parseCommandLineString("RuleName", inherited: false)
        parser.parseCommandLineString("CommandLine", inherited: false)
        super.init(parser, basedOnSpec, isGeneric: isGeneric)
    }

    required convenience init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        return cbc.scope.migExecutablePath().str
    }

    public override func resolveExecutablePath(_ cbc: CommandBuildContext, _ path: Path) -> Path {
        return resolveExecutablePath(cbc.producer, Path(computeExecutablePath(cbc)))
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let mig = self.resolveExecutablePath(cbc.producer, Path(computeExecutablePath(cbc))).str
        let target = cbc.scope.evaluate(cbc.scope.namespace.parseString("$(CURRENT_ARCH)-$(LLVM_TARGET_TRIPLE_VENDOR)-$(LLVM_TARGET_TRIPLE_OS_VERSION)$(LLVM_TARGET_TRIPLE_SUFFIX)"))
        let arch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH)
        let variant = cbc.scope.evaluate(BuiltinMacros.CURRENT_VARIANT)
        let dirVariantSuffix = variant != "normal" ? "-\(variant)" : ""
        let input = cbc.input
        let inputBasename = input.absolutePath.basename
        let inputPrefix = Path(inputBasename).withoutSuffix
        var outputs = [Path]()

        let generateServer: Bool, generateClient: Bool
        switch input.migCodegenFiles {
        case .some(.client):
            (generateClient, generateServer) = (true, false)
        case .some(.server):
            (generateClient, generateServer) = (false, true)
        case .some(.both):
            (generateClient, generateServer) = (true, true)
        default:
            (generateClient, generateServer) = (true, false)
        }

        let derivedFileDir = Path(cbc.scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).str + dirVariantSuffix).normalize()
        let clientHeaderPath: Path, clientCodePath: Path
        if generateClient {
            clientHeaderPath = derivedFileDir.join(arch).join(inputPrefix + ".h")
            clientCodePath = derivedFileDir.join(arch).join(inputPrefix + "User.c")
            delegate.declareOutput(FileToBuild(absolutePath: clientHeaderPath, fileType: cbc.producer.lookupFileType(identifier: "sourcecode.c.h")!))
            delegate.declareGeneratedSourceFile(clientHeaderPath)
            delegate.declareOutput(FileToBuild(absolutePath: clientCodePath, fileType: cbc.producer.lookupFileType(identifier: "sourcecode.c.c")!))
            delegate.declareGeneratedSourceFile(clientCodePath)
            outputs.append(clientHeaderPath)
            outputs.append(clientCodePath)
        } else {
            clientHeaderPath = Path.null
            clientCodePath = Path.null
        }

        let serverHeaderPath: Path, serverCodePath: Path
        if generateServer {
            serverHeaderPath = derivedFileDir.join(arch).join(inputPrefix + "Server.h")
            serverCodePath = derivedFileDir.join(arch).join(inputPrefix + "Server.c")
            // FIXME: We shouldn't need to lookup known file types.
            delegate.declareOutput(FileToBuild(absolutePath: serverHeaderPath, fileType: cbc.producer.lookupFileType(identifier: "sourcecode.c.h")!))
            delegate.declareGeneratedSourceFile(serverHeaderPath)
            // FIXME: We shouldn't need to lookup known file types.
            delegate.declareOutput(FileToBuild(absolutePath: serverCodePath, fileType: cbc.producer.lookupFileType(identifier: "sourcecode.c.c")!))
            delegate.declareGeneratedSourceFile(serverCodePath)
            outputs.append(serverHeaderPath)
            outputs.append(serverCodePath)
        } else {
            serverHeaderPath = Path.null
            serverCodePath = Path.null
        }

        var args = [mig, "-arch", arch, "-target", target]

        args += ["-header", clientHeaderPath.str, "-user", clientCodePath.str, "-sheader", serverHeaderPath.str, "-server", serverCodePath.str]
        args += cbc.scope.evaluate(BuiltinMacros.OTHER_MIGFLAGS)
        for str in cbc.scope.evaluate(BuiltinMacros.HEADER_SEARCH_PATHS) {
            args.append("-I" + str)
        }
        args.append(input.absolutePath.str)

        let enabledIndexBuildArena = cbc.scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)

        // Mig calls xcrun behind the scenes, so pass MIGCC in the env with
        // the pre-resolved path to cc, and DEVELOPER_DIR as a backstop.
        var env: [(String, String)] = environmentFromSpec(cbc, delegate)
        env.append(("DEVELOPER_DIR", cbc.scope.evaluate(BuiltinMacros.DEVELOPER_DIR).str))
        env.append(("MIGCC", resolveExecutablePath(cbc.producer, Path("cc")).str))

        // FIXME: Populate the outputs.
        delegate.createTask(type: self, ruleInfo: ["Mig"] + outputs.map { $0.str } + [input.absolutePath.str, variant, arch], commandLine: args, environment: EnvironmentBindings(env), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: outputs, action: nil, execDescription: resolveExecutionDescription(cbc, delegate), preparesForIndexing: enabledIndexBuildArena, enableSandboxing: enableSandboxing)
    }

    static func discoveredMiGToolInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path) async throws -> DiscoveredMiGToolSpecInfo {
        try await DiscoveredMiGToolSpecInfo.parseProjectNameAndSourceVersionStyleVersionInfo(producer, delegate, commandLine: [toolPath.str, "-version"]) { versionInfo in
            DiscoveredMiGToolSpecInfo(toolPath: toolPath, toolVersion: versionInfo.version)
        }
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, scope.migExecutablePath())

        // Get the info from the global cache.
        do {
            return try await Self.discoveredMiGToolInfo(producer, delegate, at: toolPath)
        } catch {
            delegate.error(error)
            return nil
        }
    }
}

extension MacroEvaluationScope {
    func migExecutablePath(lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Path {
        return evaluate(BuiltinMacros.MIG_EXEC).nilIfEmpty ?? Path("mig")
    }
}
