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

@main
struct Main {
    static func main() async {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard arguments.count >= 1 else {
            try? FileHandle.standardError.write(contentsOf: Data("usage: \(ProcessInfo.processInfo.arguments[0]) output-dir [input-file...]\n".utf8))
            exit(EXIT_FAILURE)
        }

        let outputDir = arguments[0]
        let inputFiles = Array(arguments[1...])

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for inputFile in inputFiles {
                    group.addTask {
                        let outputFile = outputDir + "/" + URL(fileURLWithPath: inputFile).lastPathComponent
                        if FileManager.default.fileExists(atPath: outputFile) {
                            try FileManager.default.removeItem(atPath: outputFile)
                        }
                        try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: inputFile)), options: [], format: nil)
                        var inputData = try Data(contentsOf: URL(fileURLWithPath: inputFile))
                        inputData.removeAll(where: { $0 == Character("\r").asciiValue }) // normalize newlines for Windows
                        try inputData.write(to: URL(fileURLWithPath: outputFile), options: .atomic)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
