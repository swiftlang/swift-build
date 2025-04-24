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
struct CMakeSmokeTest: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var args = ArgumentExtractor(arguments)

        let hostOS = try OS.host()

        guard let cmakePath = args.extractOption(named: "cmake-path").last else { throw Errors.missingRequiredOption("--cmake-path") }
        print("using cmake at \(cmakePath)")
        let cmakeURL = URL(filePath: cmakePath)
        guard let ninjaPath = args.extractOption(named: "ninja-path").last else { throw Errors.missingRequiredOption("--ninja-path") }
        print("using ninja at \(ninjaPath)")
        let ninjaURL = URL(filePath: ninjaPath)
        guard let sysrootPath = args.extractOption(named: "sysroot-path").last else { throw Errors.missingRequiredOption("--sysroot-path") }
        print("using sysroot at \(sysrootPath)")

        let moduleCachePath = context.pluginWorkDirectoryURL.appending(component: "module-cache").path()

        let swiftBuildURL = context.package.directoryURL
        let swiftBuildBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-build")
        print("swift-build: \(swiftBuildURL.path())")

        let swiftToolsSupportCoreURL = try findSiblingRepository("swift-tools-support-core", swiftBuildURL: swiftBuildURL)
        let swiftToolsSupportCoreBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-tools-support-core")

        let swiftSystemURL = try findSiblingRepository("swift-system", swiftBuildURL: swiftBuildURL)
        let swiftSystemBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-system")

        let llbuildURL = try findSiblingRepository("llbuild", swiftBuildURL: swiftBuildURL)
        let llbuildBuildURL = context.pluginWorkDirectoryURL.appending(component: "llbuild")

        let swiftArgumentParserURL = try findSiblingRepository("swift-argument-parser", swiftBuildURL: swiftBuildURL)
        let swiftArgumentParserBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-argument-parser")

        let swiftDriverURL = try findSiblingRepository("swift-driver", swiftBuildURL: swiftBuildURL)
        let swiftDriverBuildURL = context.pluginWorkDirectoryURL.appending(component: "swift-driver")

        for url in [swiftToolsSupportCoreBuildURL, swiftSystemBuildURL, llbuildBuildURL, swiftArgumentParserBuildURL, swiftDriverBuildURL, swiftBuildBuildURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let sharedSwiftFlags = [
            "-sdk", sysrootPath,
            "-module-cache-path", moduleCachePath
        ]

        let cMakeProjectArgs = [
            "-DArgumentParser_DIR=\(swiftArgumentParserBuildURL.appending(components: "cmake", "modules").path())",
            "-DLLBuild_DIR=\(llbuildBuildURL.appending(components: "cmake", "modules").path())",
            "-DTSC_DIR=\(swiftToolsSupportCoreBuildURL.appending(components: "cmake", "modules").path())",
            "-DSwiftDriver_DIR=\(swiftDriverBuildURL.appending(components: "cmake", "modules").path())",
            "-DSwiftSystem_DIR=\(swiftSystemBuildURL.appending(components: "cmake", "modules").path())"
        ]

        let sharedCMakeArgs = [
            "-G", "Ninja",
            "-DCMAKE_MAKE_PROGRAM=\(ninjaPath)",
            "-DCMAKE_BUILD_TYPE:=Debug",
            "-DCMAKE_Swift_FLAGS='\(sharedSwiftFlags.joined(separator: " "))'"
        ] + cMakeProjectArgs

        print("Building swift-tools-support-core")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftToolsSupportCoreURL.path()], workingDirectory: swiftToolsSupportCoreBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftToolsSupportCoreBuildURL)
        print("Built swift-tools-support-core")

        if hostOS != .macOS {
            print("Building swift-system")
            try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftSystemURL.path()], workingDirectory: swiftSystemBuildURL)
            try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftSystemBuildURL)
            print("Built swift-system")
        }

        print("Building llbuild")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + ["-DLLBUILD_SUPPORT_BINDINGS:=Swift", llbuildURL.path()], workingDirectory: llbuildBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: llbuildBuildURL)
        print("Built llbuild")

        print("Building swift-argument-parser")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + ["-DBUILD_TESTING=NO", "-DBUILD_EXAMPLES=NO", swiftArgumentParserURL.path()], workingDirectory: swiftArgumentParserBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftArgumentParserBuildURL)
        print("Built swift-argument-parser")

        print("Building swift-driver")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftDriverURL.path()], workingDirectory: swiftDriverBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftDriverBuildURL)
        print("Built swift-driver")

        print("Building swift-build in \(swiftBuildBuildURL)")
        try await Process.checkNonZeroExit(url: cmakeURL, arguments: sharedCMakeArgs + [swiftBuildURL.path()], workingDirectory: swiftBuildBuildURL)
        try await Process.checkNonZeroExit(url: ninjaURL, arguments: [], workingDirectory: swiftBuildBuildURL)
        print("Built swift-build")
    }

    func findSiblingRepository(_ name: String, swiftBuildURL: URL) throws -> URL {
        let url = swiftBuildURL.deletingLastPathComponent().appending(component: name)
        print("\(name): \(url.path())")
        guard FileManager.default.fileExists(atPath: url.path()) else { throw Errors.missingRepository(url.path()) }
        return url
    }
}

enum Errors: Error {
    case processError(terminationReason: Process.TerminationReason, terminationStatus: Int32)
    case missingRequiredOption(String)
    case missingRepository(String)
    case unimplementedForHostOS
}

enum OS {
    case macOS
    case linux
    case windows

    static func host() throws -> Self {
        #if os(macOS)
        return .macOS
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        throw Errors.unimplementedForHostOS
        #endif
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

    static func checkNonZeroExit(url: URL, arguments: [String], workingDirectory: URL, environment: [String: String]? = nil) async throws {
        print("\(url.path()) \(arguments.joined(separator: " "))")
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        try await process.run()
        if process.terminationStatus != 0 {
            throw Errors.processError(terminationReason: process.terminationReason, terminationStatus: process.terminationStatus)
        }
    }
}
