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
import SWBCore
import SWBMacro
import Foundation

protocol ShellBasedTaskProducer {
    func handleFileLists(_ tasks: inout [any PlannedTask], _ inputs: inout [any PlannedNode], _ outputs: inout [any PlannedNode], _ environment: inout [String: String] , _ scope: MacroEvaluationScope, _ inputFileLists: [any PlannedNode], _ outputFileLists: [any PlannedNode], lookup: @escaping ((MacroDeclaration) -> MacroExpression?)) async

    func pathForResolvedFileList(_ scope: MacroEvaluationScope, prefix: String, fileList: Path) -> Path

    func parseFileList(_ scope: MacroEvaluationScope, _ path: Path, isInputList: Bool, lookup: @escaping ((MacroDeclaration) -> MacroExpression?)) -> [any PlannedNode]

    func serializeFileList(_ tasks: inout [any PlannedTask], to path: Path, paths: [any PlannedNode], context: TaskProducerContext) async -> any PlannedNode

    static func isSandboxingEnabled(_ context: TaskProducerContext, _ buildPhase: BuildPhase) -> Bool
}

extension ShellBasedTaskProducer where Self: StandardTaskProducer {
    func parseXCFileList<T>(_ path: Path, scope: MacroEvaluationScope, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil, transform: (Path) -> T = { $0 }) throws -> [T] {
        let contents = try readFileContents(path).asString
        return contents
            .split(separator: "\n")
            .compactMap { line in
                let line = line.trimmingCharacters(in: .whitespaces)

                // Lines starting with '#' are treated as comments.
                if line.isEmpty || line.hasPrefix("#") { return nil }

                // Evaluate the actual macro expansion.
                let expr: MacroStringExpression = scope.namespace.parseString(line)
                let path = Path(scope.evaluate(expr, lookup: lookup))
                return path.isEmpty ? nil : transform(path)
            }
    }

    func parseFileList(_ scope: MacroEvaluationScope, _ path: Path, isInputList: Bool, lookup: @escaping ((MacroDeclaration) -> MacroExpression?)) -> [any PlannedNode] {
        do {
            return try parseXCFileList(path, scope: scope, lookup: lookup) { path -> (any PlannedNode) in
                if isInputList && (SWBFeatureFlag.treatScriptInputsAsDirectoryNodes.value || scope.evaluate(BuiltinMacros.USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES)) {
                    return context.createDirectoryTreeNode(context.makeAbsolute(path).normalize(), excluding: [])
                }
                else {
                    return context.createNode(context.makeAbsolute(path).normalize())
                }
            }
        } catch {
            // TODO: <rdar://problem/40458171> use the file system error object to emit a more informative error message
            context.error("Unable to load contents of file list: '\(path.str)'")
            return []
        }
    }

    func handleFileLists(_ tasks: inout [any PlannedTask], _ inputs: inout [any PlannedNode], _ outputs: inout [any PlannedNode], _ environment: inout [String: String] , _ scope: MacroEvaluationScope, _ inputFileLists: [any PlannedNode], _ outputFileLists: [any PlannedNode], lookup: @escaping ((MacroDeclaration) -> MacroExpression?) = { _ in nil }) async {
        // The set of both the input and the output file lists need to be tracked as inputs to the script as they are required to exist before the task can actually run.
        inputs += inputFileLists
        inputs += outputFileLists

        // Handle each of the input file lists.
        for (n, fileList) in inputFileLists.enumerated() {
            let resolvedPaths = parseFileList(scope, fileList.path, isInputList: true, lookup: lookup)

            // Track the entire set of items from the list as inputs for the script phase.
            inputs += resolvedPaths

            // Export the resolved paths to a file that can be consumed by the user's script phase.
            let resolvedListPath = pathForResolvedFileList(scope, prefix: "InputFileList", fileList: fileList.path)
            let resolvedListNode = await serializeFileList(&tasks, to: resolvedListPath, paths: resolvedPaths, context: context)

            // Overwrite the existing file path with the path that contains the resolved items.
            environment["SCRIPT_INPUT_FILE_LIST_\(n)"] = resolvedListPath.str

            // It is vital that this generated file is also tracked as an input.
            inputs.append(resolvedListNode)
        }

        // Handle each of the output file lists.
        for (n, fileList) in outputFileLists.enumerated() {
            let resolvedPaths = parseFileList(scope, fileList.path, isInputList: false, lookup: lookup)

            // Track the entire set of items from the list as outputs for the script phase.
            outputs += resolvedPaths

            // Export the resolved paths to a file that can be consumed by the user's script phase.
            let resolvedListPath = pathForResolvedFileList(scope, prefix: "OutputFileList", fileList: fileList.path)
            let resolvedListNode = await serializeFileList(&tasks, to: resolvedListPath, paths: resolvedPaths, context: context)

            // Overwrite the existing file path with the path that contains the resolved items.
            environment["SCRIPT_OUTPUT_FILE_LIST_\(n)"] = resolvedListPath.str

            // It is vital that this generated file is also tracked as an input.
            inputs.append(resolvedListNode)
        }
    }

    static func isSandboxingEnabled(_ context: TaskProducerContext, _ buildPhase: BuildPhase) -> Bool {
        let scope = context.settings.globalScope

        if !scope.evaluate(BuiltinMacros.ENABLE_USER_SCRIPT_SANDBOXING) {
            return false
        }
        if scope.evaluate(BuiltinMacros.__ALLOW_EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES) && scope.evaluate(BuiltinMacros.EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES).contains(buildPhase.name) {
            context.note("Sandboxing turned-off for '\(buildPhase.name)' because it is listed in EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES")
            return false
        }
        return true
    }
}
