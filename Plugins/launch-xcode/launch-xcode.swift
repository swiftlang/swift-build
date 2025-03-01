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

import PackagePlugin
import Foundation

@main
struct LaunchXcode: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        #if !os(macOS)
        throw LaunchXcodeError.unsupportedPlatform
        #else
        var args = ArgumentExtractor(arguments)
        var configuration: PackageManager.BuildConfiguration = .debug
        // --release
        if args.extractFlag(named: "release") > 0 {
            configuration = .release
        } else {
            // --configuration release
            let configurationOptions = args.extractOption(named: "configuration")
            if configurationOptions.contains("release") {
                configuration = .release
            }
        }

        let buildResult = try packageManager.build(.all(includingTests: false), parameters: .init(configuration: configuration, echoLogs: true))
        guard buildResult.succeeded else { return }
        guard let buildServiceURL = buildResult.builtArtifacts.map({ $0.url }).filter({ $0.lastPathComponent == "SWBBuildServiceBundle" }).first else {
            throw LaunchXcodeError.buildServiceURLNotFound
        }

        print("Launching Xcode...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-F", "-W", "--env", "XCBBUILDSERVICE_PATH=\(buildServiceURL.path())", "-b", "com.apple.dt.Xcode"]
        process.standardOutput = nil
        process.standardError = nil
        try await process.run()
        if process.terminationStatus != 0 {
            throw LaunchXcodeError.launchFailed
        }
        #endif
    }
}

enum LaunchXcodeError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case buildServiceURLNotFound
    case launchFailed

    var description: String {
        switch self {
        case .unsupportedPlatform:
            return "This command is only supported on macOS"
        case .buildServiceURLNotFound:
            return "Failed to determine path to built SWBBuildServiceBundle"
        case .launchFailed:
            return "Launching Xcode failed, did you remember to pass `--disable-sandbox`?"
        }
    }
}

extension Process {
    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            terminationHandler = { _ in
                continuation.resume()
            }

            do {
                try run()
            } catch {
                terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
