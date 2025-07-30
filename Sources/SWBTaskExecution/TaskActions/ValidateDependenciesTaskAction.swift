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
public import SWBCore
import SWBUtil

public final class ValidateDependenciesTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "validate-dependencies"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let commandLine = Array(task.commandLineAsStrings)
        guard commandLine.count >= 1, commandLine[0] == "builtin-validate-dependencies" else {
            outputDelegate.emitError("unexpected arguments: \(commandLine)")
            return .failed
        }

        guard let context = (task.payload as? ValidateDependenciesPayload)?.moduleDependenciesContext else {
            if let payload = task.payload {
                outputDelegate.emitError("invalid task payload: \(payload)")
            } else {
                outputDelegate.emitError("empty task payload")
            }
            return .failed
        }

        do {
            var allFiles = Set<String>()
            var allImports = Set<DependencyValidationInfo.Import>()
            var unsupported = false

            for inputPath in task.inputPaths {
                let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath.str))
                let info = try JSONDecoder().decode(DependencyValidationInfo.self, from: inputData)

                switch info.payload {
                case .clangDependencies(let files):
                    files.forEach {
                        allFiles.insert($0)
                    }
                case .swiftDependencies(let imports):
                    imports.forEach {
                        allImports.insert($0)
                    }
                case .unsupported:
                    unsupported = true
                }
            }

            var diagnostics: [Diagnostic] = []

            if unsupported {
                diagnostics.append(contentsOf: context.makeDiagnostics(missingDependencies: nil))
            } else {
                // Filter missing C dependencies by known Swift dependencies to avoid duplicate diagnostics between the two.
                let swiftImports = allImports.map { $0.dependency.name }
                let missingDependencies = context.computeMissingDependencies(files: allFiles.map { Path($0) })?.filter {
                    !swiftImports.contains($0.name)
                }

                diagnostics.append(contentsOf: context.makeDiagnostics(missingDependencies: missingDependencies))
                diagnostics.append(contentsOf: context.makeDiagnostics(imports: allImports.map { ($0.dependency, $0.importLocations) }))
            }

            for diagnostic in diagnostics {
                outputDelegate.emit(diagnostic)
            }

            if diagnostics.contains(where: { $0.behavior == .error }) {
                return .failed
            }
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }

        return .succeeded
    }
}
