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
import Foundation
import SWBUtil

public final class LdTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "ld"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate,
    ) async -> CommandResult {
        return await TaskDependencyVerification.exec(
            ctx: TaskExecutionContext(
                task: task,
                dynamicExecutionDelegate: dynamicExecutionDelegate,
                executionDelegate: executionDelegate,
                clientDelegate: clientDelegate,
                outputDelegate: outputDelegate
            ),
            adapter: LdAdapter()
        )
    }

    private struct LdAdapter: TaskDependencyVerification.Adapter {
        typealias T = TraceData

        let outerTraceFileEnvVar = "LD_TRACE_FILE"

        private static let inherentDependencies = [
            "libSystem.B.tbd",
            "libobjc.A.tbd",
        ]

        func verify(
            ctx: TaskExecutionContext,
            traceData: LdTaskAction.TraceData,
            dependencySettings: DependencySettings
        ) throws -> Bool {
            return try verifyFiles(
                ctx: ctx,
                files: traceData.all().filter { !LdTaskAction.LdAdapter.inherentDependencies.contains($0.basename) },
                dependencySettings: dependencySettings
            )
        }
    }

    private struct TraceData : Decodable {

        let dynamic: [Path]?
        let weak: [Path]?
        let reExports: [Path]?
        let upwardDynamic: [Path]?
        let delayInit: [Path]?
        let archives: [Path]?

        func all() -> Set<Path> {
            var all = Set<Path>()
            [dynamic, weak, reExports, upwardDynamic, delayInit, archives].forEach { all.formUnion($0 ?? []) }
            return all
        }

        enum CodingKeys: String, CodingKey {
            case reExports = "re-exports"
            case dynamic = "dynamic"
            case weak = "weak"
            case upwardDynamic = "upward-dynamic"
            case delayInit = "delay-init"
            case archives = "archives"
        }
        
    }
}
