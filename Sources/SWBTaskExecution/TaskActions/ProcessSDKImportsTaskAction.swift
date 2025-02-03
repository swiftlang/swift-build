//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
public import SWBCore
import SWBUtil

public final class ProcessSDKImportsTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "process-sdk-imports"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let commandLine = Array(task.commandLineAsStrings.suffix(3))
        if commandLine.count != 3, commandLine[0] != "builtin-process-sdk-imports" {
            outputDelegate.emitError("unexpected arguments: \(commandLine)")
            return .failed
        }
        let input = commandLine[1]
        let output = commandLine[2]

        do {
            let inputData = try Data(contentsOf: URL(fileURLWithPath: input))
            let versioned = try JSONDecoder().decode(VersionedSDKImports.self, from: inputData)
            if versioned.version != 1 {
                outputDelegate.emitError("input at '\(input)' is version \(versioned.version) but only version 1 is supported")
                return .failed
            }

            let imports = try JSONDecoder().decode(SDKImportsV1.self, from: inputData)
            // Shorten all paths to just basenames to not leak private information from the developer's machine.
            let sanitizedImports = SDKImportsV1(
                version: imports.version,
                output: Path(imports.output).basename,
                arch: imports.arch,
                linker: imports.linker,
                apiListVersion: imports.apiListVersion,
                platform: imports.platform,
                deploymentVersion: imports.deploymentVersion,
                sdkVersion: imports.sdkVersion,
                inputs: imports.inputs.map {
                    SDKImportsV1.Input(
                        path: Path($0.path).basename,
                        sdkImports: $0.sdkImports
                    )
                }
            )

            let outputData = try JSONEncoder().encode(sanitizedImports)
            try outputData.write(to: URL(fileURLWithPath: output))
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
        return .succeeded
    }
}

private struct VersionedSDKImports: Codable {
    let version: Int
}

private struct SDKImportsV1: Codable {
    let version: Int
    let output: String
    let arch: String
    let linker: String
    let apiListVersion: Int
    let platform: String
    let deploymentVersion: String
    let sdkVersion: String
    let inputs: [Input]

    struct Import: Codable {
        let installName: String
        let symbols: [String]
    }

    struct Input: Codable {
        let path: String
        let sdkImports: [Import]
    }
}
