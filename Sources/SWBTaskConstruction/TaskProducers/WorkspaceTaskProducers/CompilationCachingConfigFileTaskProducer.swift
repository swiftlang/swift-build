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

final class CompilationCachingConfigFileTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func generateTasks() async -> [any SWBCore.PlannedTask] {
        var tasks = [any PlannedTask]()
        do {
            struct CompilationCachingConfigs {
                let OutputDir: Path
                let CASConfigContent: ByteString
                let PrefixMapConfigContent: ByteString?
            }

            let configFiles = try Dictionary(
                grouping: await targetContexts.concurrentMap(maximumParallelism: 100) { (targetContext: TaskProducerContext) async throws -> CompilationCachingConfigs? in
                    let scope = targetContext.settings.globalScope

                    // Aggregated targets doesn't need to build anything.
                    if targetContext.configuredTarget?.target.type == .aggregate {
                        return nil
                    }

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

                    let path = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR)
                    let casOpts = try CASOptions.create(scope, .compiler(.other(dialectName: "swift")))
                    struct CASConfig: Encodable {
                        let CASPath: String
                        let PluginPath: String?
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    let casConfigContent = try encoder.encode(CASConfig(CASPath: casOpts.casPath.str, PluginPath: casOpts.pluginPath?.str))

                    let prefixMapConfigContent: ByteString?
                    if !scope.evaluate(BuiltinMacros.CLANG_ENABLE_PREFIX_MAPPING) && !scope.evaluate(BuiltinMacros.SWIFT_ENABLE_PREFIX_MAPPING) && scope.evaluate(BuiltinMacros.CLANG_OTHER_PREFIX_MAPPINGS).isEmpty && scope.evaluate(BuiltinMacros.SWIFT_OTHER_PREFIX_MAPPINGS).isEmpty {
                        prefixMapConfigContent = nil
                    } else {
                        func rsplit(_ string: String, separator: Character) -> (String, String)? {
                            guard let splitIndex = string.lastIndex(of: separator) else {
                                return nil
                            }
                            let key = String(string[..<splitIndex])
                            let value = String(string[string.index(after: splitIndex)...])
                            return (key, value)
                        }

                        var prefixMaps: [String: String] = [:]
                        if scope.evaluate(BuiltinMacros.CLANG_ENABLE_PREFIX_MAPPING) || !scope.evaluate(BuiltinMacros.SWIFT_ENABLE_PREFIX_MAPPING) {
                            prefixMaps["/^sdk"] = scope.evaluate(BuiltinMacros.SDKROOT).str
                            prefixMaps["/^xcode"] = scope.evaluate(BuiltinMacros.DEVELOPER_DIR).str
                            prefixMaps["/^src"] = scope.evaluate(BuiltinMacros.PROJECT_DIR).str
                            prefixMaps["/^derived"] = scope.evaluate(BuiltinMacros.PROJECT_TEMP_DIR).str
                            prefixMaps["/^built"] = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).str
                        }
                        if scope.evaluate(BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE) {
                            prefixMaps.merge(
                                scope.evaluate(BuiltinMacros.CLANG_OTHER_PREFIX_MAPPINGS).compactMap { entry in
                                    rsplit(entry, separator: "=").map { (value, key) in (key, value) }
                                }, uniquingKeysWith: { _, new in new })
                        }
                        if scope.evaluate(BuiltinMacros.SWIFT_ENABLE_COMPILE_CACHE) {
                            prefixMaps.merge(
                                scope.evaluate(BuiltinMacros.SWIFT_OTHER_PREFIX_MAPPINGS).compactMap { entry in
                                    rsplit(entry, separator: "=").map { (value, key) in (key, value) }
                                }, uniquingKeysWith: { _, new in new })
                        }
                        prefixMapConfigContent = try ByteString(encoder.encode(prefixMaps))
                    }
                    return CompilationCachingConfigs(OutputDir: path, CASConfigContent: ByteString(casConfigContent), PrefixMapConfigContent: prefixMapConfigContent)
                }.compactMap { $0 }
            ) { $0.OutputDir }

            for (configPath, configs) in configFiles {
                if configs.count > 1 {
                    // Check that all configs for this path have the same content
                    let firstConfig = configs[0]
                    for conf in configs[1...] {
                        if conf.CASConfigContent != firstConfig.CASConfigContent {
                            throw StubError.error("Inconsistent CAS configuration for path '\(configPath.str)': multiple targets produce different configurations for the same path\n'\(firstConfig.CASConfigContent)' vs. '\(conf.CASConfigContent)'")
                        }
                        if conf.PrefixMapConfigContent != firstConfig.PrefixMapConfigContent {
                            throw StubError.error("Inconsistent PrefixMap configuration for path '\(configPath.str)': multiple targets produce different configurations for the same path\n'\(firstConfig.PrefixMapConfigContent ?? "")' vs. '\(conf.PrefixMapConfigContent ?? "")'")
                        }
                    }
                }
                guard let config = configs.first else {
                    continue
                }
                await appendGeneratedTasks(&tasks) { delegate in
                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: config.OutputDir.join(".cas-config")), delegate, ruleName: "WriteCASConfig", contents: config.CASConfigContent, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate])
                }
                if let prefixMapConfigContent = config.PrefixMapConfigContent {
                    await appendGeneratedTasks(&tasks) { delegate in
                        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], output: config.OutputDir.join("compilation-prefix-map.json")), delegate, ruleName: "WriteCompilePrefixMap", contents: prefixMapConfigContent, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate])
                    }
                }
            }
        } catch {
            self.context.error(error.localizedDescription)
        }
        return tasks
    }
}
