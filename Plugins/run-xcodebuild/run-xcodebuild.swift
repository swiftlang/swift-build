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
struct RunXcodebuild: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        #if !os(macOS)
        throw RunXcodebuildError.unsupportedPlatform
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
            throw RunXcodebuildError.buildServiceURLNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + args.remainingArguments
        process.environment = ProcessInfo.processInfo.environment.merging(["XCBBUILDSERVICE_PATH": buildServiceURL.path()]) { _, new in new }
        try await process.run()
        if process.terminationStatus != 0 {
            throw RunXcodebuildError.xcodebuildError(terminationReason: process.terminationReason, terminationStatus: process.terminationStatus)
        }
        #endif
    }
}

enum RunXcodebuildError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case buildServiceURLNotFound
    case xcodebuildError(terminationReason: Process.TerminationReason, terminationStatus: Int32)

    var description: String {
        switch self {
        case .unsupportedPlatform:
            return "This command is only supported on macOS"
        case .buildServiceURLNotFound:
            return "Failed to determine path to built SWBBuildServiceBundle"
        case let .xcodebuildError(terminationReason, terminationStatus):
            let reason = switch terminationReason {
            case .exit:
                "status code"
            case .uncaughtSignal:
                "uncaught signal"
            @unknown default:
                preconditionFailure()
            }
            return "xcodebuild exited with \(reason) \(terminationStatus), did you remember to pass `--disable-sandbox`?"
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
