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

import SWBCore
import SWBUtil
import SWBMacro

extension TaskProducerContext {
    func sandbox(builder: inout PlannedTaskBuilder, delegate: any TaskGenerationDelegate) {
        guard !settings.globalScope.evaluate(BuiltinMacros.DISABLE_TASK_SANDBOXING) else {
            return
        }
        let context = self

        let taskIdentifier = TaskIdentifier(forTarget: builder.forTarget, ruleInfo: builder.ruleInfo, priority: builder.priority)

        let scope = context.settings.globalScope

        let inputs = builder.inputs.filter { !($0 is (PlannedVirtualNode)) }
        let outputs = builder.outputs.filter { !($0 is (PlannedVirtualNode)) }

        // Write the ".sb" file on disk right next to the ".sh" file
        let sentinel = taskIdentifier.sandboxProfileSentinel

        let sandboxProfilePath = scope.evaluate(BuiltinMacros.TEMP_DIR).join("\(sentinel).sb")
        let sandboxProfileNode = context.createNode(sandboxProfilePath)

        let inputsAncestors: [Path] = inputs.map { $0.path }.ancestors.sorted()
        let outputsAncestors: [Path] = outputs.map { $0.path }.ancestors.sorted()

        let sandboxProfileContents = OutputByteStream()
        // Glue together these three things:
        //   * a list of input files that are allowed to be read and not modified
        //   * a list of output files to be read and modified
        //   * the generic template for sandboxes

        sandboxProfileContents <<< "(version 1)" <<< "\n"
        sandboxProfileContents <<< "(allow default)" <<< "\n" // Required; Removing this will cause testEnsureProperlyDeclaredInputOutputSucceeds to fail

        // TODO: rdar://87285630 (User script sandboxing: network requests)
        // Ideally we'd like the build system to track HTTP artifacts and guide the users to include them as dependencies.
        // However as of now Swift Build does not track these kind of dependencies.
        // For now we allow all network requests so that existing workflows can continue to function
        // sandboxProfileContents <<< "(deny network*)" <<< "\n"

        // Ask sandbox-exec to report errors directly through kernel and not userspace
        sandboxProfileContents <<< "(disable-callouts)" <<< "\n"

        sandboxProfileContents <<< "(import \"/System/Library/Sandbox/Profiles/bsd.sb\")" <<< "\n\n"

        // content in `SRCROOT` and build dirs would be denied (unless declared in inputs/outputs)
        // content in other places is allowed
        sandboxProfileContents <<< ";; Only deny SRCROOT, PROJECT_DIR and build dirs" <<< "\n"

        /// Note: Hierarchy of the directories is as follows:
        /// * ${DERIVED_DATA_DIR}/.../${TEMP_DIR}/.../${DERIVED_FILE_DIR}/
        /// * The shell script is written to ${TEMP_DIR}
        /// * Finally, ${TEMP_DIR} === ${TARGET_TEMP_DIR}
        /// The order of allow/deny statements in the profile needs to precisely follow the directory hierarchy

        // (1/3) deny $SRCROOT, $PROJECT_DIR, $OBJROOT, $SYMROOT and $DSTROOT (and some others)
        let denyByDefault: [(String, String)] = [
            BuiltinMacros.SRCROOT,
            BuiltinMacros.PROJECT_DIR,
            BuiltinMacros.OBJROOT,
            BuiltinMacros.SYMROOT,
            BuiltinMacros.DSTROOT,
            BuiltinMacros.SHARED_PRECOMPS_DIR,
            BuiltinMacros.CACHE_ROOT,
            BuiltinMacros.CONFIGURATION_BUILD_DIR,
            BuiltinMacros.CONFIGURATION_TEMP_DIR,
            BuiltinMacros.LOCROOT,
            BuiltinMacros.LOCSYMROOT,
            BuiltinMacros.INDEX_PRECOMPS_DIR,
            BuiltinMacros.INDEX_DATA_STORE_DIR,
        ].compactMap { symbolName in
            let value = scope.evaluate(symbolName)
            return value.isEmpty ? nil : (symbolName.name, value.str)
        }

        for (symbolName, _) in denyByDefault {
            sandboxProfileContents <<< "(deny file-read* file-write* (subpath (param \"\(symbolName)\")) (with message \"\(sentinel)\"))" <<< "\n"
        }

        // (2/2) allow ${TEMP_DIR} (our policy is to allow target temporary folders)
        sandboxProfileContents <<< "(allow file-read* file-write* (subpath (param \"TEMP_DIR\")))" <<< "\n"
        sandboxProfileContents <<< "\n"

        // (3/3) In (2) we allowed ${TEMP_DIR} and its subdirectories. Explicitly deny ${DERIVED_FILE_DIR}.
        sandboxProfileContents <<< "(deny file-read* file-write* (subpath (param \"DERIVED_FILE_DIR\")) (with message \"\(sentinel)\"))" <<< "\n"

        // See rdar://87776575 (Sandbox blocks getcwd() unexpectedly, which blocks Foundation.Data(contentsOf: relativePath))
        sandboxProfileContents <<< "(allow file-read* (literal (param \"SRCROOT\")))" <<< "\n"
        sandboxProfileContents <<< "(allow file-read* (literal (param \"PROJECT_DIR\")))" <<< "\n"

        sandboxProfileContents <<< ";; Allow file-read for all the parents of declared input/outputs" <<< "\n"

        for i in 0..<inputsAncestors.count {
            sandboxProfileContents <<< "(allow file-read* (literal (param \"SCRIPT_INPUT_ANCESTOR_\(i)\")))" <<< "\n"
        }

        for i in 0..<outputsAncestors.count {
            sandboxProfileContents <<< "(allow file-read* (literal (param \"SCRIPT_OUTPUT_ANCESTOR_\(i)\")))" <<< "\n"
        }

        sandboxProfileContents <<< ";; Allow file-read for resolved (flattened) inputs" <<< "\n"
        for (i, input) in inputs.enumerated() {
            sandboxProfileContents <<< "(allow file-read* (\(input.sandboxProfilePathAccessType) (param \"SCRIPT_INPUT_FILE_\(i)\")))" <<< "\n"
        }
        sandboxProfileContents <<< "\n"

        sandboxProfileContents <<< ";; Allow read+write for declared and resolved (flattened) outputs" <<< "\n"
        for (i, output) in outputs.enumerated() {
            // Swift Build supports listing a directory in outputs only when:
            // * the directory will be empty
            // * the directory will be non-empty but the precise and fixed list of its contents are included in outputs as well
            //
            // For this reason in the profile we always use "literal" instead of "subpath" for outputs.
            //
            // This implies scripts which need to create a directory
            // but don't know the full set of files within the directory hierarchy ahead of time
            // cannot adopt sandboxing at the moment.

            sandboxProfileContents <<< "(allow file-read* file-write* (\(output.sandboxProfilePathAccessType) (param \"SCRIPT_OUTPUT_FILE_\(i)\")))" <<< "\n"
        }
        sandboxProfileContents <<< "\n"

        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: sandboxProfilePath), delegate, contents: sandboxProfileContents.bytes, permissions: 0o755, preparesForIndexing: builder.preparesForIndexing, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])

        var params: [String] = []
        params += outputs.enumerated().flatMap { (i, output) in ["-D", "SCRIPT_OUTPUT_FILE_\(i)=\(output.path.str)"] }
        params += inputs.enumerated().flatMap { (i, input) in ["-D", "SCRIPT_INPUT_FILE_\(i)=\(input.path.str)"] }
        params += inputsAncestors.enumerated().flatMap { (i, path) in ["-D", "SCRIPT_INPUT_ANCESTOR_\(i)=\(path.str)"] }
        params += outputsAncestors.enumerated().flatMap { (i, path) in ["-D", "SCRIPT_OUTPUT_ANCESTOR_\(i)=\(path.str)"] }

        // Symbols in denyByDefault
        for (symbolName, value) in denyByDefault {
            params += ["-D", "\(symbolName)=\(value)"]
        }

        params += ["-D", "TEMP_DIR=\(scope.evaluate(BuiltinMacros.TEMP_DIR).str)"]
        params += ["-D", "TARGET_TEMP_DIR=\(scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).str)"]
        params += ["-D", "DERIVED_FILE_DIR=\(scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).str)"]

        // The generated sandbox profile is also an input.
        builder.inputs.append(sandboxProfileNode)
        builder.commandLine = ["/usr/bin/sandbox-exec"] + params.map { .literal(ByteString(encodingAsUTF8: $0)) } + ["-f", .literal(ByteString(encodingAsUTF8: sandboxProfilePath.str))] + builder.commandLine
    }
}

extension PlannedNode {
    /// The access type to use for this input or output node, for a `file-read` or `file-write` permission in the sandbox profile language.
    ///
    /// - returns: `subpath` for directory tree nodes, allowing access to the entire directory hierarchy, or `literal` for all other node types (e.g. path nodes), allowing access only to the specified path.
    /// - note: A task can have a mixture of different node types in its inputs or outputs, except in the case of shell script build phases. There, the user cannot control the types of individual input or output nodes, but rather the build system will create all input nodes as directory tree nodes if the `USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES` build setting is enabled, and regular path nodes if it is not. Output nodes of shell script build phases are always regular path nodes - never directory tree nodes.
    fileprivate var sandboxProfilePathAccessType: String {
        return self is (PlannedDirectoryTreeNode) ? "subpath" : "literal"
    }
}
