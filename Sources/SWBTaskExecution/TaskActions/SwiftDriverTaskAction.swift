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
import SWBLibc
import SWBUtil
import Foundation
internal import SwiftDriver
internal import SWBMacro
internal import SWBProtocol

final public class SwiftDriverTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-invocation"
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        // A dynamically requested planning job should always execute
        return false
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        for (index, input) in (task.executionInputs ?? []).enumerated() {
            dynamicExecutionDelegate.requestInputNode(node: input, nodeID: UInt(index))
        }
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        guard let payload = task.payload as? SwiftTaskPayload, let driverPayload = payload.driverPayload else {
            outputDelegate.emitError("Invalid payload for Swift integrated driver support")
            return .failed
        }

        let dependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph

        guard let target = task.forTarget else {
            outputDelegate.emitError("Can't plan Swift driver invocation without a target.")
            return .failed
        }

        guard task.commandLine.starts(with: ["builtin-SwiftDriver", "--"]) else {
            outputDelegate.emitError("Unexpected command line prefix")
            return .failed
        }

        do {
            let environment: [String: String]
            if let executionEnvironment = executionDelegate.environment {
                environment = executionEnvironment.merging(task.environment.bindingsDictionary, uniquingKeysWith: { a, b in b })
            } else {
                environment = task.environment.bindingsDictionary
            }

            let commandLine = task.commandLineAsStrings.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: false)[1]
            let (success, planBuildDiagnostics) = dependencyGraph.planBuild(key: driverPayload.uniqueID,
                                                                            compilerLocation: driverPayload.compilerLocation,
                                                                            target: target,
                                                                            args: Array(commandLine),
                                                                            workingDirectory: task.workingDirectory,
                                                                            tempDirPath: driverPayload.tempDirPath,
                                                                            explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                                                                            environment: environment,
                                                                            eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                                                                            casOptions: driverPayload.casOptions)

            // Read and emit any serialized diagnostics reported by the scanner. Then report any diagnostics from planBuild
            // which were not present in the serialized diagnostics. We match on the message and location only, because
            // the diagnostics returned by the API are lower-fidelity compared to those in the serialized diagnostics file.
            let serializedDiagnostics: [Diagnostic]
            if let scannerDiagnosticsPath = driverPayload.scannerDiagnosticsOutputPath {
                serializedDiagnostics = dynamicExecutionDelegate.operationContext.readSerializedDiagnostics(
                    at: scannerDiagnosticsPath,
                    workingDirectory: task.workingDirectory,
                    appendToOutputStream: true,
                    fs: executionDelegate.fs
                )
            } else {
                serializedDiagnostics = []
            }
            struct SeenDiagnostic: Hashable {
                var message: String
                var location: Diagnostic.Location
            }
            var seenDiagnostics: Set<SeenDiagnostic> = []
            for serializedDiagnostic in serializedDiagnostics {
                outputDelegate.emit(serializedDiagnostic)
                seenDiagnostics.insert(.init(message: serializedDiagnostic.data.description, location: serializedDiagnostic.location))
            }
            for diagnostic in planBuildDiagnostics {
                // Diagnostics returned by planBuild may have rendered fix-its as part of the message, so only compare the first line.
                if seenDiagnostics.contains(.init(message: diagnostic.data.description.split("\n").0, location: diagnostic.location)) {
                    continue
                } else {
                    outputDelegate.emit(diagnostic)
                }
            }

            guard success else { return .failed }
        }

        do {
            if executionDelegate.userPreferences.enableDebugActivityLogs {
                let plannedBuild = try dependencyGraph.queryPlannedBuild(for: driverPayload.uniqueID)

                let jobsDebugDescription: (ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob>) -> String = {
                    $0.map({ "\t\t\($0.debugDescription)" }).joined(separator: "\n")
                }

                var message = "Swift Driver planned jobs for target \(task.forTarget?.target.name ?? "<unknown>") (\(driverPayload.architecture)-\(driverPayload.variant)):"
                if driverPayload.explicitModulesEnabled {
                    message += "\n\tExplicit Modules:\n" + jobsDebugDescription(plannedBuild.explicitModulesPlannedDriverJobs()[...])
                }
                message += "\n\tCompilation Requirements:\n" + jobsDebugDescription(plannedBuild.compilationRequirementsPlannedDriverJobs())
                message += "\n\tCompilation:\n" + jobsDebugDescription(plannedBuild.compilationPlannedDriverJobs())
                message += "\n\tAfter Compilation:\n" + jobsDebugDescription(plannedBuild.afterCompilationPlannedDriverJobs())
                message += "\n\tVerification:\n" + jobsDebugDescription(plannedBuild.verificationPlannedDriverJobs())

                outputDelegate.emitNote(message)
            }

            if driverPayload.explicitModulesEnabled,
               let dependencyValidationPayload = payload.dependencyValidationPayload
            {
                let payload: DependencyValidationInfo.Payload
                if let imports = try await dependencyGraph.mainModuleImportModuleDependencies(for: driverPayload.uniqueID) {
                    payload = .swiftDependencies(imports: imports.map { .init(dependency: $0.0, importLocations: $0.importLocations) })
                    outputDelegate.incrementTaskCounter(.moduleDependenciesValidatedTasks)
                    outputDelegate.incrementTaskCounter(.moduleDependenciesScanned, by: imports.count)
                } else {
                    payload = .unsupported
                    outputDelegate.incrementTaskCounter(.moduleDependenciesNotValidatedTasks)
                }
                let validationInfo = DependencyValidationInfo(payload: payload)
                _ = try executionDelegate.fs.writeIfChanged(
                    dependencyValidationPayload.dependencyValidationOutputPath,
                    contents: ByteString(
                        JSONEncoder(outputFormatting: .sortedKeys).encode(validationInfo)
                    )
                )
            }
            else {
                outputDelegate.incrementTaskCounter(.moduleDependenciesNotValidatedTasks)
            }

            if driverPayload.reportRequiredTargetDependencies != .no && driverPayload.explicitModulesEnabled, let target = task.forTarget {
                let dependencyModuleNames = try await dependencyGraph.queryTransitiveDependencyModuleNames(for: driverPayload.uniqueID)
                for dependencyModuleName in dependencyModuleNames {
                    if let targetDependencies = dynamicExecutionDelegate.operationContext.definingTargetsByModuleName[dependencyModuleName] {
                        for targetDependency in targetDependencies {
                            guard targetDependency.guid != target.guid else {
                                continue
                            }
                            executionDelegate.taskDiscoveredRequiredTargetDependency(target: target, antecedent: targetDependency, reason: .swiftModuleDependency(dependentModuleName: driverPayload.moduleName, dependencyModuleName: dependencyModuleName), warningLevel: driverPayload.reportRequiredTargetDependencies)
                        }
                    }
                }
            }

            if let linkerResponseFilePath = driverPayload.linkerResponseFilePath {
                var responseFileCommandLine: [String] = []
                if driverPayload.explicitModulesEnabled {
                    for swiftmodulePath in try dependencyGraph.querySwiftmodulesNeedingRegistrationForDebugging(for: driverPayload.uniqueID) {
                        responseFileCommandLine.append(contentsOf: ["-Xlinker", "-add_ast_path", "-Xlinker", "\(swiftmodulePath)"])
                    }
                }
                let contents = ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: responseFileCommandLine, format: driverPayload.linkerResponseFileFormat))
                try executionDelegate.fs.createDirectory(linkerResponseFilePath.dirname, recursive: true)
                try executionDelegate.fs.write(linkerResponseFilePath, contents: contents, atomically: true)
            }

            return .succeeded
        } catch {
            outputDelegate.error("Unexpected error in querying jobs from dependency graph: \(error)")
            return .failed
        }
    }
}
