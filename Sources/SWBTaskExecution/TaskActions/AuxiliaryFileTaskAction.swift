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
import SWBLibc
public import SWBCore
import Foundation

public final class AuxiliaryFileTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "auxiliary-file"
    }

    public let context: AuxiliaryFileTaskActionContext

    public init(_ context: AuxiliaryFileTaskActionContext) {
        self.context = context
        super.init()
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        for diagnostic in context.diagnostics {
            switch diagnostic.kind {
            case .error:
                outputDelegate.error(diagnostic.message)
            case .warning:
                outputDelegate.warning(diagnostic.message)
            case .note:
                outputDelegate.note(diagnostic.message)
            }
        }

        do {
            if context.forceWrite {
                // If we're forcing a write, remove and then write regardless of content.
                if context.logContents {
                    let contents = try executionDelegate.fs.read(context.input)
                    outputDelegate.emitOutput(contents)
                }
                try? executionDelegate.fs.remove(context.output)
                try executionDelegate.fs.copy(context.input, to: context.output)
                try executionDelegate.fs.touch(context.output)
            } else {
                // Otherwise read the content and check to see if it has changed.
                let contents = try executionDelegate.fs.read(context.input)
                if context.logContents {
                    outputDelegate.emitOutput(contents)
                }
                _ = try executionDelegate.fs.writeIfChanged(context.output, contents: contents)
            }
        } catch {
            outputDelegate.emitError("unable to write file '\(context.output.str)': \(error.localizedDescription)")
            return .failed
        }
        if let permissions = context.permissions {
            do {
                if try executionDelegate.fs.getFilePermissions(context.output) != permissions {
                    try executionDelegate.fs.setFilePermissions(context.output, permissions: permissions)
                }
            } catch {
                outputDelegate.emitError("unable to set permissions on file '\(context.output.str)': \(error.localizedDescription)")
                return .failed
            }
        }
        return .succeeded
    }

    // MARK: Serialization

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(7) {
            serializer.serialize(context.output)
            serializer.serialize(context.input)
            serializer.serialize(context.permissions)
            serializer.serialize(context.forceWrite)
            serializer.serialize(context.diagnostics)
            serializer.serialize(context.logContents)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        let output: Path = try deserializer.deserialize()
        let input: Path = try deserializer.deserialize()
        let permissions: Int? = try deserializer.deserialize()
        let forceWrite: Bool = try deserializer.deserialize()
        let diagnostics: [AuxiliaryFileTaskActionContext.Diagnostic] = try deserializer.deserialize()
        let logContents: Bool = try deserializer.deserialize()
        self.context = AuxiliaryFileTaskActionContext(output: output, input: input, permissions: permissions, forceWrite: forceWrite, diagnostics: diagnostics, logContents: logContents)
        try super.init(from: deserializer)
    }

    public override func computeInitialSignature() -> ByteString {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(7) {
            serializer.serialize(context.output)
            // We must not serialize the entire path of the 'input', because it will include the build description ID, which may change in cases when this task should not be invalidated.
            serializer.serialize(context.input.basename)
            serializer.serialize(context.permissions)
            serializer.serialize(context.forceWrite)
            serializer.serialize(context.diagnostics)
            serializer.serialize(context.logContents)
            super.serialize(to: serializer)
        }
        let md5 = InsecureHashContext()
        md5.add(bytes: serializer.byteString)
        return md5.signature
    }
}

extension AuxiliaryFileTaskActionContext.Diagnostic: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        switch kind {
        case .error:
            serializer.serialize(UInt(0))
        case .warning:
            serializer.serialize(UInt(1))
        case .note:
            serializer.serialize(UInt(2))
        }
        serializer.serialize(message)
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        let kind: AuxiliaryFileTaskActionContext.Diagnostic.Kind = try {
            let code: UInt = try deserializer.deserialize()
            switch code {
            case 0:
                return .error
            case 1:
                return .warning
            case 2:
                return .note
            default:
                throw DeserializerError.incorrectType("Unexpected type code for AuxiliaryFileTaskActionContext.Diagnostic.Kind: \(code)")
            }
        }()
        let message: String = try deserializer.deserialize()
        self.init(kind: kind, message: message)
    }
}
