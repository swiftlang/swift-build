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

public import SWBCore
import SWBLibc
import SWBUtil
public import SWBLLBuild
import Foundation

/// rdar://125894897 (🚨 fetchOperationServiceEndpoint seems completely broken for app extensions implemented in Swift (SwiftUI: Swift entry point data not found.))
///
/// We need to the final stub executor to contain the `__swift5_entry` trampoline to
/// jump to the debug dylib's `__swift5_entry` IFF it has one. Prior to addressing
/// the above, we always emitted the trampoline and assumed it would be inert unless
/// used. But for older delegate style extensions, the presence of this linker
/// section determines the launch lifecycle used.
///
/// To accommodate this at link time, we are choosing a variant of the stub executor
/// library, one with or without the entry point, based on whether the entry point
/// is present in the user's debug dylib. To do this, we need to inspect the binary
/// so we'll do this in a new task that will write the chosen library path to a file
/// list that is added to the stub executor link arguments.
public final class ConstructStubExecutorInputFileListTaskAction: TaskAction {

    /// A unique identifier for the tool, used for binding in llbuild.
    override public class var toolIdentifier: String {
        "construct-stub-executor-input-file-list"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        guard task.inputPaths.count == 3 else {
            outputDelegate.emitError(
                "Expected 3 inputs to task for constructing stub executor input file list but got \(task.inputPaths.count)"
            )
            return .failed
        }

        let fs = executionDelegate.fs

        let baseLibraryVariantPath = task.inputPaths[0]
        let swiftEntryLibraryVariantPath = task.inputPaths[1]
        let dylibPath = task.inputPaths[2]

        guard task.outputPaths.count == 1 else {
            outputDelegate.emitError(
                "Expected only one output to task for constructing stub executor input list file but got \(task.outputPaths.count)"
            )
            return .failed
        }

        let fileListPath = task.outputPaths[0]

        do {
            let machOData = try MachO(data: fs.read(dylibPath))
            let slices = try machOData.slices()

            let slicesWithEntryPointSection = try machOData.slices()
                .filter { try $0.containsSwift5EntrySection }

            let chosenLibraryPath: Path
            let containsSwift5EntrySection = slicesWithEntryPointSection.count > 0
            if containsSwift5EntrySection {
                if slices.count != slicesWithEntryPointSection.count {
                    // It should not be the case that you'd have some slices with and without the Swift
                    // entry point. If we happen to encounter that, let's print out a warning.
                    outputDelegate.emitWarning(
                        "Only \(slicesWithEntryPointSection.count) out of \(slices.count) slices in the debug dylib MachO contained Swift entry point sections. Using stub executor library with Swift entry point."
                    )
                }
                else {
                    outputDelegate.emitNote("Using stub executor library with Swift entry point.")
                }
                chosenLibraryPath = swiftEntryLibraryVariantPath
            } else {
                outputDelegate.emitNote("Using stub executor library without Swift entry point.")
                chosenLibraryPath = baseLibraryVariantPath
            }

            try fs.write(fileListPath, contents: ByteString(encodingAsUTF8: "\(chosenLibraryPath.str)\n"))

            return .succeeded
        }
        catch {
            outputDelegate.emitError("Unable to process debug dylib: \(error.localizedDescription)")
            return .failed
        }
    }

}
