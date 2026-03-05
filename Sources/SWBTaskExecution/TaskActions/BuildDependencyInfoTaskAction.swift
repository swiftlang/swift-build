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

import ArgumentParser
import Foundation

public import SWBCore
internal import SWBMacro
internal import SWBProtocol
import SWBUtil

public final class BuildDependencyInfoTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "build-dependency-info"
    }

    private struct Options: ParsableArguments {
        @Argument var inputs: [Path]
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        guard let outputPath = task.outputPaths.first else {
            outputDelegate.emitError("could not determine output path")
            return .failed
        }

        do {
            let options = try Options.parse(Array(task.commandLineAsStrings.dropFirst()))

            var errors = [String]()
            var targets = [BuildDependencyInfo.TargetDependencyInfo]()
            for dumpDependencyPath in options.inputs {
                let dumpDependencyData = try Data(contentsOf: URL(fileURLWithPath: dumpDependencyPath.str))
                let dumpDependencyInfo = try JSONDecoder().decode(BuildDependencyInfo.self, from: dumpDependencyData)
                errors.append(contentsOf: dumpDependencyInfo.errors)
                targets.append(contentsOf: dumpDependencyInfo.targets)
            }

            let dependencyInfo = BuildDependencyInfo(targets: targets, errors: errors)
            let outputData = try JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(dependencyInfo)
            let outputURL = URL(fileURLWithPath: outputPath.str)
            try outputData.write(to: outputURL)
        } catch {
            outputDelegate.emitError(error.localizedDescription)
            return .failed
        }

        return .succeeded
    }
}
