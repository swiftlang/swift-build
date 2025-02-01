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

import SWBUtil

class SWBServiceConsoleDumpPIDCommand: SWBServiceConsoleCommand {
    static let name = "dumpPID"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return .success(SWBServiceConsoleResult(output: "service pid = \(invocation.console.service.subprocessPID ?? -1)\n"))
    }
}

class SWBServiceConsoleIsAliveCommand: SWBServiceConsoleCommand {
    static let name = "isAlive"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        switch await Result.catching({ try await invocation.console.service.checkAlive() }) {
        case .success:
            return .success(SWBServiceConsoleResult(output: "is alive? yes\n"))
        case let .failure(error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleSetConfigCommand: SWBServiceConsoleCommand {
    static let name = "setConfig"

    static func usage() -> String {
        return name + " <key> <value>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        if invocation.commandLine.count != 3 {
            return SWBServiceConsoleError.invalidCommandError(description: "usage: " + usage() + "\n")
        }
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        switch await Result.catching({ try await invocation.console.service.setConfig(key: invocation.commandLine[1], value: invocation.commandLine[2]) }) {
        case .success:
            return .success(SWBServiceConsoleResult(output: "ok\n"))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleClearAllCachesCommand: SWBServiceConsoleCommand {
    static let name = "clearAllCaches"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        switch await Result.catching({ try await invocation.console.service.clearAllCaches() }) {
        case .success:
            return .success(SWBServiceConsoleResult(output: "ok\n"))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleShowStatisticsCommand: SWBServiceConsoleCommand {
    static let name = "showStatistics"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        switch await Result.catching({ try await invocation.console.service.getStatisticsDump() }) {
        case .success(let value):
            return .success(SWBServiceConsoleResult(output: value))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleVersionCommand: SWBServiceConsoleCommand {
    static let name = "version"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        do {
            let version = try SwiftBuildGetVersion()
            return .success(SWBServiceConsoleResult(output: "\(version)\n"))
        } catch {
            return .failure(SWBServiceConsoleError.failedCommandError(description: "Could not determine Swift Build version: \(error)"))
        }
    }
}

class SWBServiceConsoleOpenIDEConsoleCommand: SWBServiceConsoleCommand {
    static let name = "openIDEConsole"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        #if os(macOS) || targetEnvironment(macCatalyst)
        DistributedNotificationCenter.default.post(name: Notification.Name("IDEOpenXCBuildConsole"), object: nil)
        return .success(SWBServiceConsoleResult(output: "ok\n"))
        #else
        return .failure(.invalidCommandError(description: "not supported on this platform\n"))
        #endif
    }
}

class SWBServiceConsoleSendPIFCommand: SWBServiceConsoleCommand {
    static let name = "sendMockPIF"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        // Send a mock PIF.
        //
        // FIXME: Move this to a file, or something.
        let workspacePIF: SWBPropertyListItem = [
            "guid": "W1",
            "name": "aWorkspace",
            "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
            "projects": ["PROJECT"]
        ]
        let projectPIF: SWBPropertyListItem = [
            "guid": "P1",
            "path": "/tmp/aProject.xcodeproj",
            "targets": [],
            "developmentRegion": "English",
            "defaultConfigurationName": "Config1",
            "buildConfigurations": [
                [
                    "guid": "BC1",
                    "name": "Config1",
                    "buildSettings": [
                        "USER_PROJECT_SETTING": "USER_PROJECT_VALUE"
                    ]
                ]
            ],
            "groupTree": [
                "guid": "G1",
                "type": "group",
                "name": "SomeFiles",
                "sourceTree": "PROJECT_DIR",
                "path": "/tmp/SomeProject/SomeFiles"
            ]
        ]
        let topLevelPIF: SWBPropertyListItem = [
            [
                "type": "workspace",
                "signature": "WORKSPACE",
                "contents": workspacePIF
            ],
            [
                "type": "project",
                "signature": "PROJECT",
                "contents": projectPIF
            ]
        ]

        do {
            let session = try await invocation.console.getOrCreateActiveSession()
            do {
                try await session.sendPIF(topLevelPIF)
                return .success(SWBServiceConsoleResult(output: "note: the PIF was sent successfully\n"))
            } catch {
                return .failure(.failedCommandError(description: "error: the PIF could not be sent: \(error)\n"))
            }
        } catch {
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleDumpDependencyInfoCommand: SWBServiceConsoleCommand {
    static let name = "dumpDependencyInfo"

    static func usage() -> String {
        return name + " <dependency-info-file>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        if invocation.commandLine.count != 2 {
            return SWBServiceConsoleError.invalidCommandError(description: "usage: " + usage() + "\n")
        }
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        let path = invocation.commandLine[1]

        do {
            let encoder = JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let data = FileManager.default.contents(atPath: path) {
                let dependencyInfo = try DependencyInfo(bytes: Array(data))
                let json = String(decoding: try encoder.encode(dependencyInfo), as: Unicode.UTF8.self)
                return .success(SWBServiceConsoleResult(output: json + "\n"))
            } else {
                return .failure(.failedCommandError(description: "error reading dependency info from \(path)\n"))
            }
        } catch {
            return .failure(.failedCommandError(description: "error reading dependency info: \(error)\n"))
        }
    }
}

class SWBServiceConsolePassThroughCommand {
    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        // These command is processed by Swift Build itself.
        //
        // FIXME: We need to be able to abstract the console output.
        let stdoutHandle = FileHandle.standardOutput
        let stderrHandle = FileHandle.standardError
        let result = await invocation.console.service.executeCommandLineTool(invocation.commandLine, workingDirectory: Path.currentDirectory,
                                                    stdoutHandler:{ data in
                                                        try! stdoutHandle.write(contentsOf: data)
        }, stderrHandler:{ data in
            try! stderrHandle.write(contentsOf: data)
        })

        if result {
            return .success(SWBServiceConsoleResult(output: ""))
        } else {
            return .failure(.failedCommandError(description: ""))
        }
    }
}

class SWBServiceConsoleDumpMessagePackCommand: SWBServiceConsolePassThroughCommand, SWBServiceConsoleCommand {
    static let name = "dumpMsgPack"

    static func usage() -> String {
        return name + " --path path"
    }
}

class SWBServiceConsoleHeadermapCommand: SWBServiceConsolePassThroughCommand, SWBServiceConsoleCommand {
    static let name = "headermap"

    static func usage() -> String {
        return name + " --dump path"
    }
}

class SWBServiceConsoleDumpClangScan: SWBServiceConsolePassThroughCommand, SWBServiceConsoleCommand {
    static let name = "clang-scan"

    static func usage() -> String {
        return name + " --dump path"
    }
}

class SWBServiceConsoleSerializedDiagnosticsCommand: SWBServiceConsolePassThroughCommand, SWBServiceConsoleCommand {
    static let name = "serializedDiagnostics"

    static func usage() -> String {
        return name + " --dump path"
    }
}

class SWBServiceConsoleHelpCommand: SWBServiceConsoleCommand {
    static let name = "help"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return .success(SWBServiceConsoleResult(output: invocation.console.commandRegistry.allCommandNames.sorted().joined(separator: "\n") + "\n"))
    }
}

class SWBServiceConsoleQuitCommand: SWBServiceConsoleCommand {
    static let name = "quit"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return .success(SWBServiceConsoleResult(output: "", shouldContinue: false))
    }
}

class SWBServiceConsoleExitCommand: SWBServiceConsoleCommand {
    static let name = "exit"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return .success(SWBServiceConsoleResult(output: "", shouldContinue: false))
    }
}

func registerGeneralCommands() {
    let commands: [any SWBServiceConsoleCommand.Type] = [
        SWBServiceConsoleDumpPIDCommand.self,
        SWBServiceConsoleIsAliveCommand.self,
        SWBServiceConsoleSetConfigCommand.self,
        SWBServiceConsoleClearAllCachesCommand.self,
        SWBServiceConsoleShowStatisticsCommand.self,
        SWBServiceConsoleVersionCommand.self,
        SWBServiceConsoleOpenIDEConsoleCommand.self,
        SWBServiceConsoleSendPIFCommand.self,
        SWBServiceConsoleDumpDependencyInfoCommand.self,
        SWBServiceConsoleDumpMessagePackCommand.self,
        SWBServiceConsoleHeadermapCommand.self,
        SWBServiceConsoleDumpClangScan.self,
        SWBServiceConsoleSerializedDiagnosticsCommand.self,
        SWBServiceConsoleHelpCommand.self,
        SWBServiceConsoleQuitCommand.self,
        SWBServiceConsoleExitCommand.self,
    ]

    for command in commands {
        SWBServiceConsoleCommandRegistry.registerCommandClass(command)
    }
}
