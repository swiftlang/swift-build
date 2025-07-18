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
import SWBMacro
import SWBCore
import SWBProtocol
import Foundation

final class ExtensionPointExtractorSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.extract-appextensionpoints"

    static func shouldConstructTask(scope: MacroEvaluationScope, productType: ProductTypeSpec?, isApplePlatform: Bool) -> Bool {
        let isNormalVariant = scope.evaluate(BuiltinMacros.CURRENT_VARIANT) == "normal"
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let isBuild = buildComponents.contains("build")
        let indexEnableBuildArena = scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let isAppProductType = productType?.conformsTo(identifier: "com.apple.product-type.application") ?? false
        let extensionPointExtractorEnabled = scope.evaluate(BuiltinMacros.EX_ENABLE_EXTENSION_POINT_GENERATION)

        let result = (
            isBuild
            && isNormalVariant
            && extensionPointExtractorEnabled
            && !indexEnableBuildArena
            && isAppProductType
            && isApplePlatform
        )
        return result
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        guard Self.shouldConstructTask(scope: cbc.scope, productType: cbc.producer.productType, isApplePlatform: cbc.producer.isApplePlatform) else {
            return
        }

        let inputs = cbc.inputs.map { input in
            return delegate.createNode(input.absolutePath)
        }.filter { node in
            node.path.fileExtension == "swiftconstvalues" 
        }
        var outputs = [any PlannedNode]()

        let outputPath = cbc.scope.evaluate(BuiltinMacros.EXTENSIONS_FOLDER_PATH).join(Path("\(cbc.scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME))-generated.appexpt"))
        outputs.append(delegate.createNode(outputPath))

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)

        delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs,
                            outputs: outputs,
                            action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing)
    }
}

final class AppExtensionPlistGeneratorSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.appextension-plist-generator"

    static func shouldConstructTask(scope: MacroEvaluationScope, productType: ProductTypeSpec?, isApplePlatform: Bool) -> Bool {
        let isNormalVariant = scope.evaluate(BuiltinMacros.CURRENT_VARIANT) == "normal"
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        let isBuild = buildComponents.contains("build")
        let indexEnableBuildArena = scope.evaluate(BuiltinMacros.INDEX_ENABLE_BUILD_ARENA)
        let isAppExtensionProductType = productType?.conformsTo(identifier: "com.apple.product-type.extensionkit-extension") ?? false
        let extensionPointAttributesGenerationEnabled = !scope.evaluate(BuiltinMacros.EX_DISABLE_APPEXTENSION_ATTRIBUTES_GENERATION)

        let result = ( isBuild
                       && isNormalVariant
                       && extensionPointAttributesGenerationEnabled
                       && !indexEnableBuildArena
                       && (isAppExtensionProductType)
                       && isApplePlatform )

        return result
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let scope = cbc.scope
        let productType = cbc.producer.productType
        let isApplePlatform = cbc.producer.isApplePlatform
        guard Self.shouldConstructTask(scope: scope, productType: productType, isApplePlatform: isApplePlatform) else {
            return
        }

        let inputs = cbc.inputs.map { input in
            return delegate.createNode(input.absolutePath)
        }.filter { node in
            node.path.fileExtension == "swiftconstvalues"
        }
        var outputs = [any PlannedNode]()
        let outputPath = cbc.output
        outputs.append(delegate.createNode(outputPath))


        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)

        delegate.createTask(type: self,
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: inputs,
                            outputs: outputs,
                            action: nil,
                            execDescription: resolveExecutionDescription(cbc, delegate),
                            enableSandboxing: enableSandboxing
        )
    }
}
