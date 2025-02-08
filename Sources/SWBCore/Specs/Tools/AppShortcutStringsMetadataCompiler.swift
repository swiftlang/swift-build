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
import Foundation
import SWBMacro

final public class AppShortcutStringsMetadataCompilerSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.appshortcutstringsmetadata"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard cbc.producer.canConstructAppIntentsSSUTask else {
            return
        }

        let stringsFileType = cbc.producer.lookupFileType(identifier: "text.plist.strings")!
        let xcstringsFileType = cbc.producer.lookupFileType(identifier: "text.json.xcstrings")!

        let appShortcutStringsFiles = cbc.inputs.filter({ ($0.fileType.conformsTo(stringsFileType) || $0.fileType.conformsTo(xcstringsFileType)) && ["AppShortcuts.strings", "AppShortcuts.xcstrings"].contains($0.absolutePath.basename) })

        guard appShortcutStringsFiles.count < 2 else {
            assertionFailure("App Shortcuts Validation task construction was passed context with more than one AppShortcut Strings file.")
            return
        }

        let assistantIntentStringsFiles = cbc.inputs.filter({ ($0.fileType.conformsTo(stringsFileType) || $0.fileType.conformsTo(xcstringsFileType)) && ["AssistantIntents.strings", "AssistantIntents.xcstrings"].contains($0.absolutePath.basename) })

        guard assistantIntentStringsFiles.count < 2 else {
            assertionFailure("App Shortcuts Validation task construction was passed context with more than one AssistantIntents Strings file.")
            return
        }

        // We expect either a single AppShortcuts.strings or a single AssistantIntents.strings or both
        guard cbc.inputs.count <= 2 else {
            assertionFailure("App Shortcuts Validation task construction was passed context with too many input files.")
            return
        }

        guard cbc.inputs.count > 0 else {
            assertionFailure("App Shortcuts Validation task construction was passed context with no input files.")
            return
        }

        var inputs: [any PlannedNode] = cbc.inputs.map { delegate.createNode($0.absolutePath) }
        guard let resourcesDir = cbc.resourcesDir else {
            assertionFailure("Resources directory does not exist")
            return
        }
        var metadataDependencyFileListFiles = [String]()
        let inputFilesList = cbc.inputs.map { $0.absolutePath.str }

        let metadataFileListPath = cbc.scope.evaluate(BuiltinMacros.LM_AUX_INTENTS_METADATA_FILES_LIST_PATH)
        if !metadataFileListPath.isEmpty {
            metadataDependencyFileListFiles.append(metadataFileListPath.str)
            inputs.append(delegate.createNode(metadataFileListPath))
        }

        if !cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            // Workaround until we have rdar://93626172 (Re-enable AppIntentsMetadataProcessor outputs)
            let inputOrderingNode = delegate.createVirtualNode("ExtractAppIntentsMetadata \(resourcesDir.join("Metadata.appintents").str )")
            inputs.append(inputOrderingNode)
        }

        let outputNodeIdentifier: String
        let filePathOutputIdentifier = cbc.inputs.map({ $0.absolutePath.str }).joined(separator: " ")
        if let configuredTarget = cbc.producer.configuredTarget {
            outputNodeIdentifier = "ValidateAppShortcutStringsMetadata \(configuredTarget.guid) \(filePathOutputIdentifier)"
        } else {
            outputNodeIdentifier = "ValidateAppShortcutStringsMetadata \(filePathOutputIdentifier)"
        }
        let outputOrderingNode = delegate.createVirtualNode(outputNodeIdentifier)

        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.LM_STRINGS_FILE_PATH_LIST:
                return cbc.scope.table.namespace.parseLiteralStringList(inputFilesList)
            case BuiltinMacros.LM_INTENTS_METADATA_FILES_LIST_PATH:
                return cbc.scope.table.namespace.parseLiteralStringList(metadataDependencyFileListFiles)
            default:
                return nil
            }
        }

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)
        delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs,
                            outputs: [outputOrderingNode],
                            action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing)
    }

    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return AppShortcutStringsValidationOutputParser.self
    }
}

/// An output parser which forwards all output unchanged, then generates diagnostics from a serialized diagnostics file passed in the payload once it is closed.
public final class AppShortcutStringsValidationOutputParser: TaskOutputParser {
    private let task: any ExecutableTask

    public let workspaceContext: WorkspaceContext
    public let buildRequestContext: BuildRequestContext
    public let delegate: any TaskOutputParserDelegate

    private enum ValidationStatus: String, Codable {
        case success
        case error
        case warning
    }

    private struct ValidationResult: Codable {
        var status: ValidationStatus
        var message: String
        var path: String?
        var line: Int?
        var languageCode: String?
        var key: String?

        var diagnosticLocation: Diagnostic.Location {
            guard let path else { return .unknown }
            if let languageCode,
               let key {
                return .path(Path(path), fileLocation: .object(identifier: "\(languageCode):\(key)"))
            }
            return .path(Path(path), line: line)
        }
    }

    /// The current buffered contents.
    var outputBuffer: [UInt8] = []

    required public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
    }

    public func write(bytes: ByteString) {
        // Keep appending to the buffer to get the full result so that we can read the JSON
        // in close(result: TaskResult?)
        outputBuffer.append(contentsOf: bytes.bytes)
    }

    public func close(result: TaskResult?) {
        defer {
            delegate.close()
        }
        // Don't try to read diagnostics if the process crashed or got cancelled as they were almost certainly not written in this case.
        if result.shouldSkipParsingDiagnostics { return }

        do {
            // TODO: rdar://119739842 (Pass diagnostic file path command line argument to appshortcutstringsvalidator)
            let bytesToParse = outputBuffer.firstRange(of: [UInt8(ascii: "["), UInt8(ascii: "\n")]).map { Array(outputBuffer[$0.startIndex...]) } ?? outputBuffer
            let validationResult: [ValidationResult] = try JSONDecoder().decode([ValidationResult].self, from: Data(bytesToParse))

            for result in validationResult {
                switch result.status {
                case .success:
                    continue
                case .warning:
                    delegate.diagnosticsEngine.emit(Diagnostic(behavior: .warning, location: result.diagnosticLocation, data: DiagnosticData(result.message)))
                case .error:
                    delegate.diagnosticsEngine.emit(Diagnostic(behavior: .error, location: result.diagnosticLocation, data: DiagnosticData(result.message)))
                }
            }
        } catch {
            delegate.diagnosticsEngine.emit(data: DiagnosticData("Unable to parse diagnostics: \(error.localizedDescription)"), behavior: .warning)
        }
    }
}
