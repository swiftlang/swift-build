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

public let reexportedBinariesDirectoryName = "ReexportedBinaries"

open class LinkerSpec : CommandLineToolSpec, @unchecked Sendable {
    /// Specifier for an individual library to be linked.
    public struct LibrarySpecifier {
        public enum Kind: CaseIterable, CustomStringConvertible {
            case `static`
            case dynamic
            case textBased
            case framework
            case object

            public var description: String {
                switch self {
                case .static:       return "static library"
                case .dynamic:      return "dynamic library"
                case .textBased:    return "text-based stub"
                case .framework:    return "framework"
                case .object:       return "object file"
                }
            }
        }

        /// The mode to use when linking the library.  Not all modes make sense for all kinds.
        public enum Mode: String, CaseIterable {
            /// Link the library normally.
            case normal
            /// Reexport the library.
            case reexport
            /// Merge the library.
            case merge
            /// Reexport the library with a bundle hook for performing debug builds of mergeable libraries.
            case reexport_merge
            /// Link the library weakly.
            case weak
        }

        /// The kind of library input.
        public let kind: Kind

        /// The path of the input.
        public let path: Path

        /// The mode to use when linking the library.  Not all modes make sense for all kinds.
        public let mode: Mode

        /// Whether the library should be found via the linker search path.
        public let useSearchPaths: Bool

        /// The per-arch path to the corresponding Swift module file, if available.
        public let swiftModulePaths: [String: Path]

        /// The per-arch path to the corresponding Swift module linker args response file, if available..
        public let swiftModuleAdditionalLinkerArgResponseFilePaths: [String: Path]

        /// When a linker item is generated from a task within the target, the `explicitDependencies` allows for a direct dependency to be added to ensure proper ordering.
        public let explicitDependencies: [Path]

        /// The path to the top-level item of the library being linked. If we're linking the binary inside a framework, then this will be the path to the framework's wrapper.
        ///
        /// This is used, for example, when we copy a linked framework into the `ReexportedBinaries` folder in the mergeable library debug workflow.
        public let topLevelItemPath: Path?

        /// The path to the dSYM associated with this library, if any.
        ///
        /// This is used to pass the path of the enclosing directory of a dSYM file for a linked library to `dsymutil` for the linking binary, as happens in the mergeable library workflow.
        public let dsymPath: Path?

        /// The XCFramework that is the source of this library. This will usually be `nil`.
        public let xcframeworkSourcePath: Path?

        /// The path to the privacy file, if one exists.
        public let privacyFile: Path?

        public init(kind: Kind, path: Path, mode: Mode, useSearchPaths: Bool, swiftModulePaths: [String: Path], swiftModuleAdditionalLinkerArgResponseFilePaths: [String: Path], explicitDependencies: [Path] = [], topLevelItemPath: Path? = nil, dsymPath: Path? = nil, xcframeworkSourcePath: Path? = nil, privacyFile: Path? = nil) {
            self.kind = kind
            self.path = path
            self.mode = mode
            self.useSearchPaths = useSearchPaths
            self.swiftModulePaths = swiftModulePaths
            self.swiftModuleAdditionalLinkerArgResponseFilePaths = swiftModuleAdditionalLinkerArgResponseFilePaths
            self.explicitDependencies = explicitDependencies
            self.topLevelItemPath = topLevelItemPath
            self.dsymPath = dsymPath
            self.xcframeworkSourcePath = xcframeworkSourcePath
            self.privacyFile = privacyFile
        }
    }

    class public override var typeName: String {
        return "Linker"
    }
    /// Use default instance for non-custom implementations.
    class public override var defaultClassType: (any SpecType.Type)? {
        return GenericLinkerSpec.self
    }

    override init(_ parser: SpecParser, _ basedOnSpec: Spec?, isGeneric: Bool) {
        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseStringList("Architectures")
        parser.parseStringList("BinaryFormats")
        parser.parseBool("SupportsInputFileList")

        super.init(parser, basedOnSpec, isGeneric: isGeneric)
    }

    convenience required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func defaultRuleInfo(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [String] {
        // When building for a single architecture, remove the architecture from the rule info so the llbuild task identifier is the same across multiple builds when switching architectures, so the binary in the product always gets re-linked.  c.f. <rdar://problem/63196141>
        var ruleInfo = super.defaultRuleInfo(cbc, delegate)
        let archs = cbc.scope.evaluate(BuiltinMacros.ARCHS)
        if let arch = archs.only {
            // Need to cast this to void to not use the form from Swift Build's Array.swift extension.
            ruleInfo.removeAll(where: { $0 == arch }) as Void
        }
        return ruleInfo
    }

    open override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    /// Custom entry point for constructing linker tasks.
    public func constructLinkerTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, libraries: [LibrarySpecifier], usedTools: [CommandLineToolSpec: Set<FileTypeSpec>]) async {
        /// Delegate to the generic machinery.
        await delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString), environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: [cbc.output], action: nil, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
    }
}

open class GenericLinkerSpec : LinkerSpec, @unchecked Sendable {
    required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: true)
    }
}
