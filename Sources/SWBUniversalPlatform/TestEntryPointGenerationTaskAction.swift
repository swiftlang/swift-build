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

import SWBUtil
import SWBCore
import SWBTaskExecution
import ArgumentParser

class TestEntryPointGenerationTaskAction: TaskAction {
    override class var toolIdentifier: String {
        "TestEntryPointGenerationTaskAction"
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        do {
            let options = try Options.parse(Array(task.commandLineAsStrings.dropFirst()))
            try executionDelegate.fs.write(options.output, contents: #"""
            #if canImport(Testing)
            import Testing
            #endif

            @main
            @available(macOS 10.15, iOS 11, watchOS 4, tvOS 11, visionOS 1, *)
            @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
            struct Runner {
                private static func testingLibrary() -> String {
                    var iterator = CommandLine.arguments.makeIterator()
                    while let argument = iterator.next() {
                        if argument == "--testing-library", let libraryName = iterator.next() {
                            return libraryName.lowercased()
                        }
                    }

                    // Fallback if not specified: run XCTest (legacy behavior)
                    return "xctest"
                }
            
                #if os(Linux)
                @_silgen_name("$ss13_runAsyncMainyyyyYaKcF")
                private static func _runAsyncMain(_ asyncFun: @Sendable @escaping () async throws -> ())

                static func main() {
                    let testingLibrary = Self.testingLibrary()
                    #if canImport(Testing)
                    if testingLibrary == "swift-testing" {
                        _runAsyncMain {
                            await Testing.__swiftPMEntryPoint() as Never
                        }
                    }
                    #endif
                }
                #else
                static func main() async {
                    let testingLibrary = Self.testingLibrary()
                    #if canImport(Testing)
                    if testingLibrary == "swift-testing" {
                        await Testing.__swiftPMEntryPoint() as Never
                    }
                    #endif
                }
                #endif
            }
            """#)
            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }
}

private struct Options: ParsableArguments {
    @Option var output: Path
}
