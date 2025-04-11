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
import SWBLibc
public import SWBCore
public import enum SWBLLBuild.BuildValueKind
import Foundation

public final class ClangScanTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        return "clang-scan-modules"
    }

    private struct Options {
        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) -o <scanning-output-path> -- <command_line_args>\n"
            }
        }

        let scanningOutput: Path
        let commandLine: [String]

        init?(_ commandLine: AnySequence<String>, workingDirectory: Path, executionDelegate: any TaskExecutionDelegate, outputDelegate: any TaskOutputDelegate) {
            var parsedOutput: Path?
            var cliArguments: [String]?
            var expandResponseFiles: Bool = false

            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"

        argumentIteration:
            while let arg = generator.next() {
                switch arg {
                case "-o":
                    if let outputPath = generator.next() {
                        parsedOutput = Path(outputPath)
                    } else {
                        break argumentIteration
                    }
                case "--expand-response-files":
                    expandResponseFiles = true
                case "--":
                    cliArguments = Array(generator)
                    break argumentIteration
                default:
                    outputDelegate.error("unexpected argument: \(arg)")
                    continue
                }
            }

            guard let parsedOutput else {
                outputDelegate.error("Scanning output path missing in command line \(Array(commandLine))")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }
            guard let cliArguments else {
                outputDelegate.error("Command line arguments missing in command line \(Array(commandLine))")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            self.scanningOutput = parsedOutput
            if expandResponseFiles {
                do {
                    self.commandLine = try ResponseFiles.expandResponseFiles(cliArguments, fileSystem: executionDelegate.fs, relativeTo: workingDirectory)
                } catch {
                    outputDelegate.error(error.localizedDescription)
                    return nil
                }
            } else {
                self.commandLine = cliArguments
            }
        }
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        fatalError("Unexpectedly called the old version of isResultValid")
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        // FIXME: Checking the CAS results here has a fundamental limitation.
        //        This scan task might belong to a compilation that is itself up-to-date and we might be forcing this task to run unnecessarily.
        //        It would be better to make this task dynamic and control it from within the compile task. This way we could avoid an unnecessary scan.
        fallback(buildValue) && areCASResultsValid(task, operationContext)
    }

    private func areCASResultsValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext) -> Bool {
        guard let clangPayload = task.payload as? ClangTaskPayload, let explicitModulesPayload = clangPayload.explicitModulesPayload else {
            return true
        }

        guard let casOptions = explicitModulesPayload.casOptions else {
            return true
        }

        guard let casDBs = try? operationContext.clangModuleDependencyGraph.getCASDatabases(libclangPath: explicitModulesPayload.libclangPath, casOptions: casOptions) else {
            return false
        }

        guard let dependencyInfo = try? operationContext.clangModuleDependencyGraph.queryDependencies(at: explicitModulesPayload.scanningOutputPath, fileSystem: localFS) else {
            return false
        }

        for includeTreeID in dependencyInfo.transitiveIncludeTreeIDs {
            // FIXME: Deduplicate the loop body amongst all ClangScanTaskAction.

            guard let isMaterialized = try? casDBs.isMaterialized(casID: includeTreeID), isMaterialized else {
                return false
            }
        }

        return true
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        for (index, input) in (task.executionInputs ?? []).enumerated() {
            dynamicExecutionDelegate.requestInputNode(node: input, nodeID: UInt(index))
        }
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        guard let clangPayload = task.payload as? ClangTaskPayload, let explicitModulesPayload = clangPayload.explicitModulesPayload else {
            outputDelegate.error("invalid payload for explicit module support")
            return .failed
        }

        guard let options = Options(task.commandLineAsStrings, workingDirectory: task.workingDirectory, executionDelegate: executionDelegate, outputDelegate: outputDelegate) else {
            outputDelegate.emitError("Unable to parse argument list.")
            return .failed
        }

        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph

        let result: ClangModuleDependencyGraph.ScanResult
        do {
            result = try clangModuleDependencyGraph.scanModuleDependencies(
                libclangPath: explicitModulesPayload.libclangPath,
                scanningOutputPath: explicitModulesPayload.scanningOutputPath,
                usesCompilerLauncher: explicitModulesPayload.usesCompilerLauncher,
                usesSerializedDiagnostics: clangPayload.serializedDiagnosticsPath?.fileExtension == "dia",
                fileCommandLine: options.commandLine,
                workingDirectory: task.workingDirectory,
                casOptions: explicitModulesPayload.casOptions,
                cacheFallbackIfNotAvailable: explicitModulesPayload.cacheFallbackIfNotAvailable,
                verifyingModule: explicitModulesPayload.verifyingModule,
                outputPath: explicitModulesPayload.outputPath.str,
                reportRequiredTargetDependencies: explicitModulesPayload.reportRequiredTargetDependencies,
                fileSystem: executionDelegate.fs
            )

        } catch DependencyScanner.Error.dependencyScanDiagnostics(let clangDiagnostics) {
            let diagnostics = clangDiagnostics.map { Diagnostic($0, workingDirectory: task.workingDirectory, appendToOutputStream: true) }
            for diag in diagnostics {
                outputDelegate.emit(diag)
            }
            if !diagnostics.contains(where: { $0.behavior == .error }) {
                outputDelegate.error("failed to scan dependencies for source '\(explicitModulesPayload.sourcePath.str)'")
            }
            return .failed
        } catch DependencyScanner.Error.dependencyScanErrorString(let errorString) {
            outputDelegate.error("There was an error scanning dependencies for source '\(explicitModulesPayload.sourcePath.str)':\n\(errorString)")
            return .failed
        } catch DependencyScanner.Error.dependencyScanUnknownError {
            outputDelegate.error("There was an unknown error scanning dependencies for source '\(explicitModulesPayload.sourcePath.str)'")
            return .failed
        } catch {
            outputDelegate.error("There was an error scanning dependencies for source '\(explicitModulesPayload.sourcePath.str)':\n\(error)")
            return .failed
        }

        var dependencyPaths = result.dependencyPaths
        if let filteringPath = explicitModulesPayload.dependencyFilteringRootPath {
            dependencyPaths = dependencyPaths.filter {
                // We intentionally do a prefix check instead of an ancestor check here, for performance reasons. The filtering path (SDK path) and paths returned by the compiler are guaranteed to be normalized, which makes this safe.
                // TODO: Replace with rdar://107496178 (libClang dependency scanner should not report system headers when -MMD is passed on the command line) when that is available.
                !$0.str.hasPrefix(filteringPath.str)
            }
        }

        if executionDelegate.userPreferences.enableDebugActivityLogs {
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: "Discovered dependency nodes:\n" + dependencyPaths.map(\.str).joined(separator: "\n") + "\n"))
        }

        for dep in dependencyPaths {
            dynamicExecutionDelegate.discoveredDependencyNode(ExecutionNode(identifier: dep.str))
        }

        if let target = task.forTarget {
            for requiredDependency in result.requiredTargetDependencies {
                guard requiredDependency.target.guid != task.forTarget?.guid else {
                    continue
                }
                executionDelegate.taskDiscoveredRequiredTargetDependency(target: target, antecedent: requiredDependency.target, reason: .clangModuleDependency(translationUnit: explicitModulesPayload.sourcePath, dependencyModuleName: requiredDependency.moduleName), warningLevel: explicitModulesPayload.reportRequiredTargetDependencies)
            }
        }

        return .succeeded
    }
}
