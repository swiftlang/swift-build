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
import SWBMacro
import Foundation
import SWBProtocol

final class CASConfigFileTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func generateTasks() async -> [any SWBCore.PlannedTask] {
        var tasks = [any PlannedTask]()
        do {
            let casConfigFiles = try Dictionary(try await targetContexts.concurrentMap(maximumParallelism: 100) { (targetContext: TaskProducerContext) async throws -> (Path, ByteString)? in
                let scope = targetContext.settings.globalScope

                // If compilation caching is not on, then there is no file to write.
                // The condition here is more relax than the actual check in the compile task generation
                // since it won't hurt if the file is not used.
                guard scope.evaluate(BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE) || scope.evaluate(BuiltinMacros.SWIFT_ENABLE_COMPILE_CACHE) else {
                    return nil
                }

                // FIXME: we need consistent CAS configuration across all languages.
                if !scope.evaluate(BuiltinMacros.COMPILATION_CACHE_REMOTE_SERVICE_PATH).isEmpty && !scope.evaluate(BuiltinMacros.COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES).isEmpty {
                    return nil
                }

                let casOpts = try CASOptions.create(scope, .compiler(.other(dialectName: "swift")))
                struct CASConfig: Encodable {
                    let CASPath: String
                    let PluginPath: String?
                }
                let content = try JSONEncoder().encode(CASConfig(CASPath: casOpts.casPath.str, PluginPath: casOpts.pluginPath?.str))
                let path = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join(".cas-config")
                return (path, ByteString(content))
            }.compactMap { $0 }, uniquingKeysWith: { first, second in
                guard first == second else {
                    throw StubError.error("Unexpected difference in CAS config file.\nPath: \(first.asString)\nContent:\(second.asString)")
                }
                return first
            })

            for (configFilePath, configFileContent) in casConfigFiles {
                await appendGeneratedTasks(&tasks) { delegate in
                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: configFilePath), delegate, contents: configFileContent, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate])
                }
            }
        } catch {
            self.context.error(error.localizedDescription)
        }
        return tasks
    }
}
