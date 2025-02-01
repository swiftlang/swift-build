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

/// The `XCTestProductTaskProducer` generates tasks specific to the XCTest product type whose outputs are inside the .xctest product.
final class XCTestProductTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return [.immediate, .unsignedProductRequirement]
    }

    func generateTasks() async -> [any PlannedTask] {
        // Only set up tasks if the target's product type is an XCTest bundle.
        guard context.productType is XCTestBundleProductTypeSpec else {
            return []
        }

        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []
        await appendGeneratedTasks(&tasks) { delegate in
            await generateCopyBaselinesTasks(scope, delegate)
        }
        return tasks
    }

    private func generateCopyBaselinesTasks(_ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        // Get the path to the baselines source.  If none is defined, then we skip it.
        let target = context.configuredTarget!.target as! StandardTarget
        guard let inputPath = target.performanceTestsBaselinesPath, inputPath.isAbsolute else {
            return
        }

        // The build description depends on the baselines path, since if it appears or disappears then we need to add or remove the copy task.
        access(path: inputPath)

        // No need to copy performance testing baselines for instalLoc
        if scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            return
        }

        // Set up the task to copy the baselines folder.
        if context.workspaceContext.fs.exists(inputPath) {
            let outputPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).join("xcbaselines")
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: inputPath, inferringTypeUsing: context)], output: outputPath)
            await context.copySpec.constructCopyTasks(cbc, delegate, executionDescription: "Copy performance testing baselines")
        }
    }
}


// MARK:


/// The `XCTestProductPostprocessingTaskProducer` generates postprocessing tasks specific the XCTest product type.  This producer's tasks involve assembling or modifying content outside of the test target's own product, often in an enclosing wrapper (the application being tested, or the test runner), so this producer is ordered after the test target's own postprocessing task producer.
final class XCTestProductPostprocessingTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        // Only set up tasks if the target's product type is an XCTest bundle.
        guard context.productType is XCTestBundleProductTypeSpec else {
            return []
        }

        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []
        await appendGeneratedTasks(&tasks) { delegate in
            if XCTestBundleProductTypeSpec.usesXCTRunner(scope) {
                await generateXCTRunnerTasks(scope, delegate)
            }
            // Presently there are no tasks generated here for a hosted test. The tasks which used to be created to embed the XCTest frameworks in the app are now created as part of the app target, in XCTestHostTaskProducer.
        }
        return tasks
    }

    private func archsForXCTRunner(_ scope: MacroEvaluationScope) -> (required: Set<String>, optional: Set<String>) {
        // The XCTestRunner is required to have at least the same ARCHS as our test bundle, minus the arm64e and/or x86_64h subtypes of their respective architecture family. The removal logic ensures we always get a link-compatible result.
        var requiredArchs = Set(scope.evaluate(BuiltinMacros.ARCHS))
        var optionalArchs = Set<String>()

        let linkCompatibleArchPairs = [
            ("arm64e", "arm64"),
            ("x86_64h", "x86_64"),
        ]

        for (arch, baseline) in linkCompatibleArchPairs {
            if requiredArchs.contains(baseline) {
                if let foundArch = requiredArchs.remove(arch) {
                    optionalArchs.insert(foundArch)
                }
            }
        }

        return (requiredArchs, optionalArchs)
    }

    /// A test target which is configured to use an XCTRunner will do the following:
    ///
    /// - Copy `XCTRunner.app` out of the platform being built for into the original target build dir using the name `$(XCTRUNNER_PRODUCT_NAME)` (where `$(PRODUCT_NAME)` is the test target's product name).
    /// - Run the Info.plist for the `XCTRunner.app` through the C preprocessor and into the `$(XCTRUNNER_PRODUCT_NAME)` bundle.
    /// - Copy the relevant testing frameworks out of the platform and into the `Frameworks` directory of `$(XCTRUNNER_PRODUCT_NAME)` bundle.
    /// - Sign the `$(XCTRUNNER_PRODUCT_NAME)` bundle.
    private func generateXCTRunnerTasks(_ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)

        guard BundleProductTypeSpec.validateBuildComponents(buildComponents, scope: scope) else { return }

        let wrapperContentsSubpath = scope.evaluate(BuiltinMacros._WRAPPER_CONTENTS_DIR)

        let unmodifiedTargetBuildDir = scope.unmodifiedTargetBuildDir

        // The signing task for the runner will depend on the tasks to copy the runner, and to copy-and-re-sign the test frameworks.
        var runnerSigningInputNodes = [any PlannedNode]()

        // Copy the XCTRunner.app for the platform the original/unmodified $(TARGET_BUILD_DIR).  We rename it using $(PRODUCT_NAME), and also rename its binary to match.
        let testRunnerSourcePath = XCTestBundleProductTypeSpec.testRunnerAppSourcePath(scope, context.platform)

        let testRunnerDstPath = unmodifiedTargetBuildDir.join(scope.evaluate(BuiltinMacros.XCTRUNNER_PRODUCT_NAME))
        let testRunnerContentsDstPath = testRunnerDstPath.join(wrapperContentsSubpath, preserveRoot: true)
        let testRunnerFrameworksDstPath = testRunnerContentsDstPath.join("Frameworks")

        do {
            // Create the top-level -Runner.app directory so the signing command has a concrete input.
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [], output: testRunnerDstPath)
            await context.mkdirSpec.constructTasks(cbc, delegate)
            // The mkdir tool will have created a virtual output node for its task, so we add it to the signing task's inputs so it knows it's a mutator.
            runnerSigningInputNodes.append(delegate.createVirtualNode("MkDir \(testRunnerDstPath.str)"))

            // Iterate through the contents of the source runner, and set up individual copy tasks for each file to copy.  (Directories are created implicitly via the file copies.)  Some files or directories will be skipped, renamed, or processed specially.
            guard context.workspaceContext.fs.isDirectory(testRunnerSourcePath) else {
                delegate.error("unable to create tasks to copy XCTRunner.app: not a directory: \(testRunnerSourcePath.str)")
                return
            }
            var worklist = Queue<Path>(try context.workspaceContext.fs.listdir(testRunnerSourcePath).sorted().map({ Path($0) }))
            while let subpath = worklist.popFirst() {
                let inputPath = testRunnerSourcePath.join(subpath)
                guard !context.workspaceContext.fs.isDirectory(inputPath) else {
                    // Certain directories we just skip entirely.
                    guard inputPath.basename != "_CodeSignature" else {
                        continue
                    }

                    // Other directories we add to the list to copy their contents.
                    let subpaths = try context.workspaceContext.fs.listdir(inputPath).sorted().map({ subpath.join($0) })
                    worklist.append(contentsOf: subpaths)
                    continue
                }

                let outputPath: Path
                var archsToPreserve = Set<String>()

                switch subpath.basename {
                case "Info.plist":
                    let infoPlistPath: Path?
                    if !scope.effectiveInputInfoPlistPath().isEmpty && context.settings.productType?.hasInfoPlist == true {
                        infoPlistPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.INFOPLIST_PATH))
                    } else {
                        infoPlistPath = nil
                    }

                    // Run the Info.plist from the test runner through macro expansion to update the bundle identifier.
                    outputPath = testRunnerDstPath.join(subpath)
                    let orderingOutput = context.createVirtualNode("Preprocess \(outputPath.str)")
                    let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: inputPath, inferringTypeUsing: context)] + (infoPlistPath.map { [FileToBuild(context: context, absolutePath: $0)] } ?? []), output: outputPath, commandOrderingOutputs: [orderingOutput])
                    await context.copyPlistSpec.constructTasks(cbc, delegate, specialArgs: [
                        "--macro-expansion",
                        "WRAPPEDPRODUCTNAME",
                        scope.evaluate(BuiltinMacros.PRODUCT_NAME) + "-Runner",

                        "--macro-expansion",
                        "WRAPPEDPRODUCTBUNDLEIDENTIFIER",
                        wrappedBundleIdentifier(for: scope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER)),

                        "--macro-expansion",
                        "TESTPRODUCTNAME",
                        scope.evaluate(BuiltinMacros.PRODUCT_NAME),

                        "--macro-expansion",
                        "TESTPRODUCTBUNDLEIDENTIFIER",
                        scope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER),
                    ] + (infoPlistPath.map {
                        ["--copy-value", "UIDeviceFamily", $0.str]
                    } ?? []), toolLookup: { decl in
                        switch decl {
                        case BuiltinMacros.VALIDATE_PLIST_FILES_WHILE_COPYING:
                            return scope.namespace.parseLiteralString("YES")
                        case BuiltinMacros.PLIST_FILE_OUTPUT_FORMAT:
                            return scope.namespace.parseLiteralString("XML")
                        default:
                            return nil
                        }
                    })
                    runnerSigningInputNodes.append(orderingOutput)
                    continue

                case "RunnerEntitlements.plist", "version.plist":
                    // Skip RunnerEntitlements.plist and version.plist because they shouldn't be in the final bundle.
                    continue

                case "XCTRunner":
                    // Copy the XCTRunner binary to the output root using the name of the top-level bundle.
                    outputPath = testRunnerDstPath.join(subpath.dirname).join(testRunnerDstPath.basenameWithoutSuffix)

                    let runnerArchs: Set<String>
                    do {
                        access(path: inputPath)
                        runnerArchs = try context.globalProductPlan.planRequest.buildRequestContext.getCachedMachOInfo(at: inputPath).architectures
                    } catch {
                        delegate.error("unable to create tasks to copy XCTRunner.app: can't determine architectures of binary: \(inputPath.str): \(error)")
                        continue
                    }

                    let (requiredArchs, optionalArchs) = archsForXCTRunner(scope)
                    archsToPreserve = requiredArchs

                    // If we have any optional architectures, add the subset of those which the XCTRunner binary actually has
                    if !optionalArchs.isEmpty {
                        archsToPreserve.formUnion(optionalArchs.intersection(runnerArchs))
                    }

                    let missingArchs = archsToPreserve.subtracting(runnerArchs)
                    if !missingArchs.isEmpty {
                        // This is a warning instead of an error to ease future architecture bringup
                        delegate.warning("missing architectures (\(missingArchs.sorted().joined(separator: ", "))) in XCTRunner.app: \(inputPath.str)")
                    }

                    // If the runner has only one architecture, perform a direct file copy since lipo can't use -extract on thin Mach-Os
                    if runnerArchs.count == 1 {
                        archsToPreserve = []
                    }

                default:
                    // Otherwise, just copy it.
                    outputPath = testRunnerDstPath.join(subpath)
                }
                // If we get here, then we'll construct a task to copy the inputPath to the outputPath.

                // Create a virtual output node to use to order the code signing command for the runner on the copy commands.
                let orderingOutput = context.createVirtualNode("Copy \(outputPath.str)")

                // Note that all of the tasks have the copy runner ordering virtual node as an output.
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: inputPath, inferringTypeUsing: context)], output: outputPath, commandOrderingOutputs: [orderingOutput])

                if !archsToPreserve.isEmpty {
                    context.lipoSpec.constructCopyAndProcessArchsTasks(cbc, delegate, archsToPreserve: archsToPreserve.sorted())
                } else {
                    await context.copySpec.constructCopyTasks(cbc, delegate)
                }

                runnerSigningInputNodes.append(orderingOutput)
            }
        }
        catch {
            // FIXME: For some reason using error.localizedDescription here results in a link error...
            delegate.error("unable to create tasks to copy XCTRunner.app: unknown error")
            return
        }

        if !scope.evaluate(BuiltinMacros.SKIP_COPYING_TEST_FRAMEWORKS) {
            // Copy the testing frameworks into the runner's Frameworks directory and re-sign them with the developer's identity.  We treat these tasks as peers to the tasks above which copy the runner.
            var frameworkPaths = Self.xctestLibraryAndFrameworkPaths(scope, context.platform, context.workspaceContext.fs) + [
                Self.swiftTestingFrameworkPath(scope, context.platform, context.workspaceContext.fs)
            ]

            for platformExtension in await context.workspaceContext.core.pluginManager.extensions(of: PlatformInfoExtensionPoint.self) {
                frameworkPaths.append(contentsOf: platformExtension.additionalTestLibraryPaths(scope: scope, platform: context.platform, fs: context.workspaceContext.fs))
            }

            for srcPath in frameworkPaths where srcPath.isAbsolute {
                // Copy the path into the runner and re-sign it if necessary.
                var copyAndReSignFrameworkOrderingNode: (any PlannedNode)? = nil
                await Self.copyAndReSignTestFramework(from: srcPath, to: testRunnerFrameworksDstPath.join(srcPath.basename), self, scope, delegate, commandOrderingOutput: &copyAndReSignFrameworkOrderingNode)
                if let copyAndReSignFrameworkOrderingNode = copyAndReSignFrameworkOrderingNode {
                    runnerSigningInputNodes.append(copyAndReSignFrameworkOrderingNode)
                }
            }
        }

        // Sign the XCTRunner.app.  We do this as a deferred producer because this task needs to depend on the GenerateDSYMFile task, as if there is a .dSYM then it is generated in the Runner.app's PlugIns directory alongside the .xctest bundle.
        context.addDeferredProducer {
            let context = self.context

            // First perform some hackery to avoid having nodes for the .xctest product end up as incorrect inputs or outputs of the sign task.
            var additionalOutputs = [any PlannedNode]()

            // The command to sign the runner also depends on the command to sign the test bundle.
            let testBundlePath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))
            runnerSigningInputNodes.append(context.createVirtualNode("CodeSign \(testBundlePath.normalize().str)"))

            // Pass the runner's binary as an input and an output since it is being mutated.
            let runnerBinarySubpathExpr = !scope.evaluate(BuiltinMacros._WRAPPER_CONTENTS_DIR).isEmpty
                ? scope.namespace.parseString("$(_WRAPPER_CONTENTS_DIR)/MacOS/$(PRODUCT_NAME)-Runner")
                : scope.namespace.parseString("/$(PRODUCT_NAME)-Runner")
            let runnerBinaryPath = testRunnerDstPath.join(scope.evaluate(runnerBinarySubpathExpr), preserveRoot: true)
            let runnerBinaryNode = context.createNode(runnerBinaryPath)
            runnerSigningInputNodes.append(runnerBinaryNode)
            runnerSigningInputNodes.append(context.createVirtualNode("Copy \(runnerBinaryPath.str)"))
            additionalOutputs.append(runnerBinaryNode)

            // If a dSYM file was generated, then add it as an input, since it will have been generated inside the Runner.app bundle.
            for variant in scope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
                if let dsymPath = self.context.producedDSYM(forVariant: variant) {
                    runnerSigningInputNodes.append(delegate.createVirtualNode("GenerateDSYMFile \(dsymPath.str)"))
                }
            }

            // And also add its _CodeSignature node as an output.
            additionalOutputs.append(context.createNode(testRunnerDstPath.join("_CodeSignature")))

            // Create a virtual note as an output in case something else wants to depend on this command.
            additionalOutputs.append(context.createVirtualNode("CodeSign \(testRunnerDstPath.str)"))

            // Finally we can create the task to sign the runner.  We provide some overrides specific to signing the runner.
            // Also, the 'product to sign' is the test bundle, because its name is the one used to determine the name of the entitlements file to use (and the test bundle and runner should be signed with the same entitlements).
            let fileToSign = FileToBuild(context: context, absolutePath: testRunnerDstPath)
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [fileToSign], commandOrderingInputs: runnerSigningInputNodes, commandOrderingOutputs: additionalOutputs)
            var tasks = [any PlannedTask]()
            await self.appendGeneratedTasks(&tasks) { delegate in
                context.codesignSpec.constructCodesignTasks(cbc, delegate, productToSign: testBundlePath, isAdditionalSignTask: true)
            }
            return tasks
        }
    }


    // MARK: Utility methods


    static fileprivate func copyAndReSignTestFramework(from srcPath: Path, to dstPath: Path, _ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate, commandOrderingInputs: [any PlannedNode] = [], commandOrderingOutput: inout (any PlannedNode)?) async {
        // Copy the test framework.
        let context = producer.context
        let copyFrameworkOrderingNode = delegate.createVirtualNode("CopyTestFramework \(dstPath.str)")
        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: srcPath, inferringTypeUsing: context)], output: dstPath, commandOrderingInputs: commandOrderingInputs, commandOrderingOutputs: [copyFrameworkOrderingNode])
        await context.copySpec.constructCopyTasks(cbc, delegate, removeHeaderDirectories: true)
        commandOrderingOutput = copyFrameworkOrderingNode

        // If this is a deployment platform, then re-sign the copied framework.
        if context.platform?.isDeploymentPlatform == true {
            let signFrameworkOrderingNode = delegate.createVirtualNode("SignTestFramework \(dstPath.str)")
            // TODO: Surprisingly, this logic is re-signing the .framework rather than the Versions/A directory inside it (when targeting macOS), which makes it different from how we sign other frameworks (e.g., in sign-after-copy for copy files build phases). Fixing this likely means also fixing the output node for the binary we create above.
            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: dstPath, inferringTypeUsing: context)], commandOrderingInputs: [copyFrameworkOrderingNode], commandOrderingOutputs: [signFrameworkOrderingNode])
            // FIXME: Passing isAdditionalSignTask here seems bogus, but otherwise we get warnings about Foo.framework/Foo not having a producer command, which I don't know how to otherwise fix.
            context.codesignSpec.constructCodesignTasks(cbc, delegate, productToSign: dstPath, isReSignTask: true, isAdditionalSignTask: true)
            commandOrderingOutput = signFrameworkOrderingNode
        }
    }

    /// The path to the copy of `Testing.framework` which should be used by clients.
    static fileprivate func swiftTestingFrameworkPath(_ scope: MacroEvaluationScope, _ platform: Platform?, _ fs: any FSProxy) -> Path {
         let testingFrameworkPath = Path(scope.evaluate(BuiltinMacros.PLATFORM_DIR)).join("Developer/Library/Frameworks/Testing.framework")
         return fs.exists(testingFrameworkPath) ? testingFrameworkPath : Path("")
     }

     /// The paths to libraries and frameworks produced by the XCTest project, including `XCTest.framework` and some
     /// of its dependencies, which should be used by clients.
     ///
     /// - Note: This does not include `Testing.framework`, since it is not produced as part of the XCTest project,
     ///   despite the fact that some of the XCTest libraries depend on it.
     ///
     /// The directory where the libraries and frameworks whose paths this function returns are located may be
     /// overridden if `scope` sets `INTERNAL_TEST_LIBRARIES_OVERRIDE_PATH`.
     static fileprivate func xctestLibraryAndFrameworkPaths(
         includingBundleInject includeBundleInject: Bool = false,
         _ scope: MacroEvaluationScope,
         _ platform: Platform?,
         _ fs: any FSProxy
     ) -> [Path] {
         func testLibrariesOverridePath() -> Path? {
             let path = Path(scope.evaluate(BuiltinMacros.INTERNAL_TEST_LIBRARIES_OVERRIDE_PATH))
             if !path.isEmpty, path.isAbsolute {
                 return path
             } else {
                 return nil
             }
         }
         let testLibrariesOverridePath = testLibrariesOverridePath()

         let frameworksDir = testLibrariesOverridePath ?? XCTestBundleProductTypeSpec.getPlatformDeveloperVariantLibraryPath(scope, platform).join("Frameworks")
         let privateFrameworksDir = testLibrariesOverridePath ?? XCTestBundleProductTypeSpec.getPlatformDeveloperVariantLibraryPath(scope, platform).join("PrivateFrameworks")
         let usrLibDir = testLibrariesOverridePath ?? XCTestBundleProductTypeSpec.getPlatformDeveloperVariantLibraryPath(scope, platform).dirname.join("usr/lib")

         var result: [Path] = []

         let publicFrameworkNames = [
             "XCTest.framework",
         ]
         for publicFrameworkName in publicFrameworkNames {
             result.append(frameworksDir.join(publicFrameworkName))
         }

         let subFrameworkNames = [
             "XCUnit.framework",
             "XCUIAutomation.framework",
         ]
         for subFrameworkName in subFrameworkNames {
             let pathInPublicFrameworksDir = frameworksDir.join(subFrameworkName)
             lazy var pathInPrivateFrameworksDir = privateFrameworksDir.join(subFrameworkName)
             if fs.exists(pathInPublicFrameworksDir) {
                 result.append(pathInPublicFrameworksDir)
             } else if fs.exists(pathInPrivateFrameworksDir) {
                 result.append(pathInPrivateFrameworksDir)
             }
         }

         let privateFrameworkNames = [
             "XCTestCore.framework",
             "XCTestSupport.framework",
             "XCTAutomationSupport.framework",
         ]
         for privateFrameworkName in privateFrameworkNames {
             result.append(privateFrameworksDir.join(privateFrameworkName))
         }

         var libraryNames = [
             "libXCTestSwiftSupport.dylib",
         ]
         if includeBundleInject {
             libraryNames.append("libXCTestBundleInject.dylib")
         }
         for libraryName in libraryNames {
             result.append(usrLibDir.join(libraryName))
         }

         return result
     }
}


// MARK:


/// The `XCTestHostTaskProducer` generates tasks relevant to a target whose product is the host for products of XCTest targets.  For example, embedding the XCTest-related frameworks and libraries in the host product.
final class XCTestHostTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []
            if isTestHostTarget() {
                await appendGeneratedTasks(&tasks) { delegate in
                    await generateTestHostTasks(scope, delegate)
                }
            }
        return tasks
    }

    private func isTestHostTarget() -> Bool {
        // If this target has any targets whose products it is hosting, then it is considered a test host target.
        // If we use this machinery to support other kinds of embedding in the future then this will need refinement to only check for *test* targets being hosted.
        if let configuredTarget = context.configuredTarget, let hostedTargets = context.globalProductPlan.hostedTargetsForTargets[configuredTarget], hostedTargets.count > 0 {
            return true
        }
        return false
    }

    /// Set up tasks for a target whose product is hosting test targets which define it as their `TEST_HOST`.
    private func generateTestHostTasks(_ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) async {
        // Note that testing frameworks are not copied for deployment builds (c.f. <rdar://problem/31948737>).
        if !scope.evaluate(BuiltinMacros.SKIP_COPYING_TEST_FRAMEWORKS), !scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
            // Copy the testing frameworks our Frameworks directory and re-sign each of them with the developer's identity.
            let frameworksPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FRAMEWORKS_FOLDER_PATH))
            // NOTE: If any new paths are added here, they may also need to be added to the list of those not to be scanned by the CopySwiftLibs task, in executableIsXCTestSupportLibrary() in EmbedSwiftStdLibTaskAction.swift.
            // NOTE: If any new paths are added here, they may also need to be added to the list of those not to be scanned by the CopySwiftLibs task, in executableIsTestSupportLibrary() in EmbedSwiftStdLibTaskAction.swift.
            var srcPaths = XCTestProductPostprocessingTaskProducer.xctestLibraryAndFrameworkPaths(includingBundleInject: true, scope, context.platform, context.workspaceContext.fs) + [
                XCTestProductPostprocessingTaskProducer.swiftTestingFrameworkPath(scope, context.platform, context.workspaceContext.fs)
            ]

            for platformExtension in await context.workspaceContext.core.pluginManager.extensions(of: PlatformInfoExtensionPoint.self) {
                srcPaths.append(contentsOf: platformExtension.additionalTestLibraryPaths(scope: scope, platform: context.platform, fs: context.workspaceContext.fs))
            }

            for srcPath in srcPaths where srcPath.isAbsolute {
                // Copy the path into the runner and re-sign it.
                await Self.copyAndReSignTestFramework(from: srcPath, to: frameworksPath.join(srcPath.basename), self, scope, delegate)
            }
        }
    }

    /// Convenience method to invoke `XCTestProductPostprocessingTaskProducer.copyAndReSignTestFramework()` without passing the  `commandOrderingOutput` parameter which this class doesn't need.
    static private func copyAndReSignTestFramework(from srcPath: Path, to dstPath: Path, _ producer: StandardTaskProducer, _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate, commandOrderingInputs: [any PlannedNode] = []) async {
        var copyAndReSignFrameworkOrderingNode: (any PlannedNode)? = nil
        await XCTestProductPostprocessingTaskProducer.copyAndReSignTestFramework(from: srcPath, to: dstPath, producer, scope, delegate, commandOrderingInputs: commandOrderingInputs, commandOrderingOutput: &copyAndReSignFrameworkOrderingNode)
    }

}
