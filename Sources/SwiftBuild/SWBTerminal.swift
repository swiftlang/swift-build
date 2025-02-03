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

import SWBLibc
import SWBUtil

import Foundation

func swbuild_handle_command_result(result: SWBServiceConsoleResult)  {
    print(result.output, terminator: "")
}

/// Process a command line.
///
/// - returns: True if the console should continue handling commands, otherwise the console should quit.
func swbuild_process_command(console: SWBBuildServiceConsole, command: String) async -> (shouldContinue: Bool, success: Bool) {
    // Ignore empty commands.
    if command.isEmpty {
        return (true, true)
    }

    // Process the line.
    let (result, success) = await console.sendCommandString(command)
    swbuild_handle_command_result(result: result)
    return (result.shouldContinue, success)
}

/// Process a command line.
///
/// - returns: True if the console should continue handling commands, otherwise the console should quit.
func swbuild_process_command(console: SWBBuildServiceConsole, arguments: [String]) async -> (shouldContinue: Bool, success: Bool) {
    // Ignore empty commands.
    if arguments.isEmpty {
        return (true, true)
    }

    // Process the line.
    let (result, success) = await console.sendCommand(arguments)
    swbuild_handle_command_result(result: result)
    return (result.shouldContinue, success)
}

func withServiceConsole<T>(connectionMode: SWBBuildServiceConnectionMode = .default, body: @escaping (_ console: SWBBuildServiceConsole) async -> T) async throws -> T {
    // Create the service and console.
    let service = try await SWBBuildService(connectionMode: connectionMode)
    let console = SWBBuildServiceConsole(service: service)
    let result = await body(console)
    try await console.close()
    await service.close()
    return result
}

func swbuild_repl() async throws -> Bool {
    // Save the terminal attributes (and restore them and exit).
    return try await withTerminalAttributes { terminalAttributes in
        return try await withServiceConsole { console in
            // Disable echo, after all readline initialization is done.
            terminalAttributes.disableEcho()

            var ok = true
            var shouldContinue = true
            while shouldContinue {
                print("swbuild> ", terminator: "")
                guard let line = readLine() else {
                    // If we received the EOF then exit.
                    print()
                    break
                }

                print(line)
                (shouldContinue, ok) = await swbuild_process_command(console: console, command: line)
            }

            return ok
        }
    }
}

public func main(args: [String] = CommandLine.arguments) async -> Int {
    do {
        // If we were given arguments, dispatch them as a single command line.
        //
        // FIXME: Refine this to be a nice batch mode.
        if args.count == 1 {
            // Run the repl.
            return try await swbuild_repl() ? 0 : 1
        }

        do {
            if ["--help", "--version"].contains(args[1]) {
                return await main(args: [args[0], String(args[1].dropFirst(2))] + args[2...])
            }

            return try await withServiceConsole { console in
                // Configure the default session parameters, based on the environment.
                //
                // This is an Xcode-defined environment variable used to propagate the built products directory.
                if let builtProductsDirPaths = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
                    // FIXME: We currently assume the first path is the actual products, and ignore all others (for other platforms). This is bogus.
                    let productsPath = URL(fileURLWithPath: builtProductsDirPaths.components(separatedBy: ":").first ?? ".", isDirectory: true)
                    if FileManager.default.fileExists(atPath: productsPath.appendingPathComponent("DevToolsCore.framework", isDirectory: true).path) {
                        console.inferiorProductsPath = productsPath.absoluteURL.path
                    }
                }

                var ok = true
                var argIndex = 1
                var shouldContinue = true
                while argIndex != args.count && shouldContinue {
                    var arguments = [String]()
                    while argIndex < args.count {
                        let arg = args[argIndex]
                        argIndex += 1
                        if arg == "--" {
                            break
                        }
                        arguments.append(arg)
                    }
                    (shouldContinue, ok) = await swbuild_process_command(console: console, arguments: arguments)
                }

                return ok ? 0 : 1
            }
        }
    } catch {
        print("Error communicating with the build service: \(error)")
        return 1
    }
}

/// Entry point for swbuild. Runs main and exits with the status code it returns.
public func main() async -> Never {
    return await exit(Int32(main()))
}
