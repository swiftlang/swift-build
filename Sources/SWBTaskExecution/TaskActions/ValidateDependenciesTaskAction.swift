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

        guard let payload = (task.payload as? ValidateDependenciesPayload) else {
            if let payload = task.payload {
                outputDelegate.emitError("invalid task payload: \(payload)")
            } else {
                outputDelegate.emitError("empty task payload")
            }
            return .failed
        }

        do {
            var allClangIncludes = Set<Path>()
            var allClangImports = Set<DependencyValidationInfo.Import>()
            var allSwiftImports = Set<DependencyValidationInfo.Import>()
            var unsupported = false

            for inputPath in task.inputPaths {
                let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath.str))
                let info = try JSONDecoder().decode(DependencyValidationInfo.self, from: inputData)

                switch info.payload {
                case .clangDependencies(let imports, let includes):
                    imports.forEach {
                        allClangImports.insert($0)
                    }
                    includes.forEach {
                        allClangIncludes.insert($0)
                    }
                case .swiftDependencies(let imports):
                    imports.forEach {
                        allSwiftImports.insert($0)
                    }
                case .unsupported:
                    unsupported = true
                }
            }

            var diagnostics: [Diagnostic] = []

            if let moduleContext = payload.moduleDependenciesContext {
                if unsupported {
                    diagnostics.append(contentsOf: moduleContext.makeDiagnostics(missingDependencies: nil))
                } else {
                    let clangMissingDeps = moduleContext.computeMissingDependencies(imports: allClangImports.map { ($0.dependency, $0.importLocations) }, fromSwift: false)
                    let swiftMissingDeps = moduleContext.computeMissingDependencies(imports: allSwiftImports.map { ($0.dependency, $0.importLocations) }, fromSwift: true)

                    // Update Swift dependencies with information from Clang dependencies on the same module.
                    var clangMissingDepsByName = [String: (ModuleDependency, importLocations: [Diagnostic.Location])]()
                    clangMissingDeps?.forEach {
                        clangMissingDepsByName[$0.0.name] = $0
                    }
                    let updatedSwiftMissingDeps: [(ModuleDependency, importLocations: [Diagnostic.Location])] = swiftMissingDeps?.map {
                        if let clangMissingDep = clangMissingDepsByName[$0.0.name] {
                            return (
                                ModuleDependency(name: $0.0.name, accessLevel: max($0.0.accessLevel, clangMissingDep.0.accessLevel)),
                                $0.importLocations + clangMissingDep.importLocations
                            )
                        } else {
                            return $0
                        }
                    } ?? []

                    // Filter missing C dependencies by known Swift dependencies to avoid duplicate diagnostics.
                    let swiftImports = Set(allSwiftImports.map { $0.dependency.name })
                    let uniqueClangMissingDeps = clangMissingDeps?.filter { !swiftImports.contains($0.0.name) } ?? []

                    diagnostics.append(contentsOf: moduleContext.makeDiagnostics(missingDependencies: uniqueClangMissingDeps + updatedSwiftMissingDeps))
                }
            }
            if let headerContext = payload.headerDependenciesContext {
                if unsupported {
                    diagnostics.append(contentsOf: headerContext.makeDiagnostics(includes: nil))
                } else {
                    diagnostics.append(contentsOf: headerContext.makeDiagnostics(includes: Array(allClangIncludes)))
                }
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
