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
import SWBUtil
import SWBMacro

final class SwiftSymbolExtractor: GenericCompilerSpec, GCCCompatibleCompilerCommandLineBuilder, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.compilers.documentation.swift-symbol-extract"

    static public func shouldConstructSymbolExtractionTask(_ cbc: CommandBuildContext) -> Bool {
        guard
            // Only extract symbols when documentation will be built
            DocumentationCompilerSpec.shouldConstructSymbolGenerationTask(cbc),
            // and when DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS is YES
            cbc.scope.evaluate(BuiltinMacros.DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS)
        else {
            return false
        }

        guard cbc.scope.evaluate(BuiltinMacros.DEFINES_MODULE) else {
            return false
        }

        if let swiftVersion = try? Version(cbc.scope.evaluate(BuiltinMacros.SWIFT_VERSION)), swiftVersion < Version(4) {
            // The `swift-symbolgraph-extract` tool requires at least Swift version 4.0
            // See https://github.com/apple/swift/blob/main/lib/Basic/Version.cpp#L292
            return false
        }

        let buildPhaseTarget = cbc.producer.configuredTarget?.target as? BuildPhaseTarget
        let willAlreadyExtractSwiftSymbolGraphFiles = buildPhaseTarget?.sourcesBuildPhase?.containsSwiftSources(cbc.producer, cbc.producer, cbc.scope, cbc.producer.filePathResolver) ?? false

        // Skip this task if Swift code will be compiled.
        return !willAlreadyExtractSwiftSymbolGraphFiles
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // Only extract symbols when documentation will be built
        guard Self.shouldConstructSymbolExtractionTask(cbc) else {
            return
        }

        // The main symbol graph files list also include zippered variants. Here we only want the path to the current variant.
        let mainSymbolGraphFiles = SwiftCompilerSpec.mainSymbolGraphFilesForCurrentArch(cbc: cbc)
        let targetTripleWithoutVersion = cbc.scope.evaluate(BuiltinMacros.SWIFT_TARGET_TRIPLE) {
            if $0 == BuiltinMacros.SWIFT_DEPLOYMENT_TARGET {
                return cbc.scope.namespace.parseString("")
            } else {
                return nil
            }
        }

        let symbolGraphOutputDir: Path
        if let onlyOutput = mainSymbolGraphFiles.only {
            symbolGraphOutputDir = onlyOutput.dirname
        } else if cbc.producer.sdkVariant != nil, let matchingOutputDir = mainSymbolGraphFiles.first(where: { $0.dirname.basename.hasSuffix(targetTripleWithoutVersion) }) {
            symbolGraphOutputDir = matchingOutputDir.dirname
        } else {
            delegate.error("Couldn't determine a directory of symbol graph files for \(cbc.scope.evaluate(BuiltinMacros.SWIFT_TARGET_TRIPLE)) among:\n\(mainSymbolGraphFiles.sorted().map { $0.str }.joined(separator: "\n"))")
            return
        }

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            // Override SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS to construct all search paths (user headers, headers, system headers, frameworks, system frameworks, etc.)
            // We do this to also include header maps.
            switch macro {
            case BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS:
                let headerSearchPaths = GCCCompatibleCompilerSpecSupport.headerSearchPathArguments(cbc.producer, cbc.scope, usesModules: true)
                let frameworkSearchPaths = GCCCompatibleCompilerSpecSupport.frameworkSearchPathArguments(cbc.producer, cbc.scope)
                let sparseSDKSearchPaths = GCCCompatibleCompilerSpecSupport.sparseSDKSearchPathArguments(cbc.producer.sparseSDKs, headerSearchPaths.headerSearchPaths, frameworkSearchPaths.frameworkSearchPaths)

                var defaultHeaderSearchPaths: [String] = headerSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

                if let vfsArgumentIndex = defaultHeaderSearchPaths.firstIndex(of: "-ivfsoverlay") {
                    // Add '-Xcc' before the VFS overlay argument and its value
                    defaultHeaderSearchPaths.insert("-Xcc", at: vfsArgumentIndex + 1)
                    defaultHeaderSearchPaths.insert("-Xcc", at: vfsArgumentIndex)
                }

                // Evaluate the original value and prefix each argument with "-I"
                let userHeaderSearchPaths = cbc.scope.evaluate(BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS).map {
                    return "-I" + $0
                }
                let defaultFrameworkSearchPaths = frameworkSearchPaths.searchPathArguments(for: self, scope:cbc.scope) + sparseSDKSearchPaths.searchPathArguments(for: self, scope: cbc.scope)

                // swift-symbolgraph-extract doesn't expect the `-iquote`, `-isystem`, or `-iframework` flags so we map those to `-I` and `-Fsystem` instead.
                let allSearchPaths = (defaultHeaderSearchPaths + userHeaderSearchPaths + defaultFrameworkSearchPaths)
                    .map { (argument: String) -> String in
                    switch argument {
                    case "-iquote", "-isystem":
                        return "-I"
                    case "-iframework":
                        return "-Fsystem"
                    default:
                        return argument
                    }
                }

                return cbc.scope.namespace.parseLiteralStringList(allSearchPaths)

            case BuiltinMacros.SWIFT_VERSION:
                // The 'swift-symbolgraph-extract' only accepts a very small subset of versions: major versions and 4.2 (but no other minor versions).
                // See https://github.com/apple/swift/blob/main/lib/Basic/Version.cpp#L292
                let swiftVersion = cbc.scope.evaluate(BuiltinMacros.SWIFT_VERSION)
                do {
                    let version = try Version(swiftVersion).normalized(toNumberOfComponents: 2)
                    if version[0] == 4 && version[1] == 2 {
                        return cbc.scope.table.namespace.parseString(version.description)
                    } else {
                        return cbc.scope.table.namespace.parseString("\(version[0])")
                    }
                } catch {
                    return nil
                }

            case BuiltinMacros.SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR:
                return cbc.scope.namespace.parseString(symbolGraphOutputDir.str)

            default:
                return nil
            }
        }

        // Extract the symbol information
        await delegate.createTask(
            type: self,
            ruleInfo: defaultRuleInfo(cbc, delegate, lookup: lookup),
            commandLine: commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString),
            environment: environmentFromSpec(cbc, delegate, lookup: lookup),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: cbc.commandOrderingInputs.map { delegate.createNode($0.path) },
            outputs: mainSymbolGraphFiles.map { delegate.createNode($0) },
            action: nil,
            execDescription: resolveExecutionDescription(cbc, delegate, lookup: lookup),
            enableSandboxing: enableSandboxing,
            additionalTaskOrderingOptions: .compilationRequirement
        )
    }
}
