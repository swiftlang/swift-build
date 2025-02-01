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

public import SWBCore
public import SWBUtil
import Foundation


public final class CodeSignTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        "code-sign-task"
    }

    public override init()
    {
        super.init()
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
        do {
            var commandLine = Array(task.commandLineAsStrings)

            // codesign defaults to an old signature version for bundles with no binary, and iOS 15 and later require a more modern signature. Detect static and codeless frameworks and sign them with --generate-pre-encrypt-hashes to generate this modern signature as a side effect. In general, we want a new option which can be passed unconditionally and which causes codesign to generate valid signatures for all bundle types including codeless bundles and static frameworks. For now, limit this behavior to static and codeless frameworks (which were never previously signed or particularly well supported at all) to limit risk because of potential side effects with other kinds of bundles.
            let preEncryptHashesFlag = "--generate-pre-encrypt-hashes"
            if !commandLine.contains(preEncryptHashesFlag), commandLine.count > 1, let frameworkPath = commandLine.last.map(Path.init)?.frameworkPath, let bundle = Bundle(path: frameworkPath.str), let frameworkBinaryType = bundle.executableIsMissingOrStatic(fs: executionDelegate.fs) {
                outputDelegate.emitNote("Signing \(frameworkBinaryType) framework with \(preEncryptHashesFlag)")
                commandLine.insert(preEncryptHashesFlag, at: 1)
            }

            try await spawn(commandLine: commandLine, environment: task.environment.bindingsDictionary, workingDirectory: task.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
        if let error = processDelegate.executionError {
            outputDelegate.error(error)
            return .failed
        }
        return processDelegate.commandResult ?? .failed
    }

    // Serialization


    public override func serialize<T: Serializer>(to serializer: T)
    {
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws
    {
        try super.init(from: deserializer)
    }
}

extension Bundle {
    enum BundleBinaryType: String {
        case codeless
        case `static`
    }

    func executableIsMissingOrStatic(fs: any FSProxy) -> BundleBinaryType? {
        guard let executablePath = (executableURL?.absoluteURL.path).map(Path.init) else {
            // We can't compute the path, so there probably is no executable.
            return .codeless
        }

        // No binary, this is a codeless bundle
        if !fs.exists(executablePath) {
            return .codeless
        }

        return pbxcp_path_is_staticOrObject(executablePath, fs: fs) ? .static : nil
    }
}
