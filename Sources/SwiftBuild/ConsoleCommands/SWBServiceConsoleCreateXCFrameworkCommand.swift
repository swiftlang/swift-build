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

import SWBProtocol
import SWBUtil

class SWBServiceConsoleCreateXCFrameworkCommand: SWBServiceConsoleCommand {
    public static let name = "createXCFramework"

    public static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        let (passed, message) = await invocation.console.service.createXCFramework(invocation.commandLine, currentWorkingDirectory: Path.currentDirectory.str, developerPath: nil)
        return passed ?
            .success(SWBServiceConsoleResult(output: message + "\n", shouldContinue: false)) :
            .failure(.failedCommandError(description: message + "\n"))
    }

    public static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        // Let the command processing handle the rest of the validation.
        return nil
    }
}

func registerXCFrameworkCommands() {
    let commands: [any SWBServiceConsoleCommand.Type] = [SWBServiceConsoleCreateXCFrameworkCommand.self]
    for command in commands {
        SWBServiceConsoleCommandRegistry.registerCommandClass(command)
    }
}

