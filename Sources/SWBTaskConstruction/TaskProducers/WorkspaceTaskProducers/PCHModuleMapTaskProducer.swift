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

import SWBCore
import SWBUtil
import Foundation
import SWBMacro

final class PCHModuleMapTaskProducer: StandardTaskProducer, TaskProducer {

    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func generateTasks() async -> [any PlannedTask] {
        var tasks = [any PlannedTask]()

        do {
            let prefixHeadersToPrecompile = try Dictionary(try await targetContexts.concurrentMap(maximumParallelism: 100) { (targetContext: TaskProducerContext) async throws -> (Path, ByteString)? in
                let scope = targetContext.settings.globalScope

                // If there is not prefix header, we are done.
                var prefixHeader = scope.evaluate(BuiltinMacros.GCC_PREFIX_HEADER)
                guard !prefixHeader.isEmpty else {
                    return nil
                }

                // Make the path absolute.
                prefixHeader = targetContext.createNode(prefixHeader).path

                let prefixModuleMapFile = ClangCompilerSpec.getPrefixHeaderModuleMap(prefixHeader, scope)

                if let prefixModuleMapFile {
                    let moduleMapContents = ByteString(encodingAsUTF8: """
                    module __PCH {
                        header "\(prefixHeader.str)"
                        export *
                    }
                    """)
                    return (prefixModuleMapFile, moduleMapContents)
                }
                return nil
            }.compactMap{ $0 }, uniquingKeysWith: { first, second in
                guard first == second else {
                    throw StubError.error("Unexpected difference in PCH module map content.\nFirst: \(first.asString)\nSecond:\(second.asString)")
                }
                return first
            })

            for (prefixModuleMapFilePath, moduleMapContents) in prefixHeadersToPrecompile {
                await appendGeneratedTasks(&tasks) { delegate in
                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: prefixModuleMapFilePath), delegate, contents: moduleMapContents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate])
                }
            }
        } catch {
            self.context.error(error.localizedDescription)
        }

        return tasks
    }
}
