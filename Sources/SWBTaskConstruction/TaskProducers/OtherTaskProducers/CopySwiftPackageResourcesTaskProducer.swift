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

/// Task producer for embedding the Swift package resource bundles into an app or framework.
final class CopySwiftPackageResourcesTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        let bundlesToEmbed = Set(scope.evaluate(BuiltinMacros.EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES))

        // Return early if we don't have any bundles to embed.
        if bundlesToEmbed.isEmpty {
            return []
        }

        // Files are copied for the "build" component, or the "api" or "headers" components if $(INSTALLAPI_COPY_PHASE) or $(INSTALLHDRS_COPY_PHASE) are enabled, respectively.
        //
        // FIXME: The latter feature here is rarely used, and not very flexible as any target which needs other copy phases won't be able to disable them selectively.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard buildComponents.contains("build")
                || buildComponents.contains("installLoc")
                || (buildComponents.contains("api") && scope.evaluate(BuiltinMacros.INSTALLAPI_COPY_PHASE))
                || (buildComponents.contains("headers") && scope.evaluate(BuiltinMacros.INSTALLHDRS_COPY_PHASE)) else {
            return []
        }

        let productTypeIdentifier = scope.evaluate(BuiltinMacros.PRODUCT_TYPE)
        func lookupProductType(_ ident: String) -> ProductTypeSpec? {
            do {
                return try context.getSpec(ident)
            } catch {
                context.error("Couldn't look up product type '\(ident)' in domain '\(context.domain)': \(error)")
                return nil
            }
        }

        guard let productType = lookupProductType(productTypeIdentifier) else {
            return []
        }

        guard let bundleProductType = lookupProductType("com.apple.product-type.bundle") else {
            return []
        }
        guard let frameworkProductType = lookupProductType("com.apple.product-type.framework") else {
            return []
        }

        // Disallow package resource bundles in non-bundle products and in frameworks (which, by being linked against, impart their
        if !productType.conformsTo(bundleProductType) || productType.conformsTo(frameworkProductType) {
            return []
        }

        var tasks: [any PlannedTask] = []

        await appendGeneratedTasks(&tasks) { delegate in
            for bundleName in bundlesToEmbed {
                let bundleFilename = bundleName + ".bundle"
                let inputPath = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(bundleFilename)

                let outputPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).join(bundleFilename)

                // Also add this output to the privacy content so we can inspect those bundles.
                delegate.declareGeneratedPrivacyPlistContent(outputPath)

                let ignoreMissingInputs = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc")
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: inputPath, inferringTypeUsing: context)], output: outputPath)
                await context.copySpec.constructCopyTasks(cbc, delegate, ignoreMissingInputs: ignoreMissingInputs)
            }
        }

        return tasks
    }
}
