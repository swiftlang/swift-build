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

import SWBBuildSystem
package import SWBCore
import SWBProtocol
import SWBServiceCore
package import SWBTaskConstruction
import SWBTaskExecution
package import SWBUtil
package import struct Foundation.UUID
import SWBMacro

/// The delegate for planning the build operation
package protocol PlanningOperationDelegate: TargetDiagnosticProducingDelegate, ActivityReporter {
    /// Emit a diagnostic for the planning operation.
    func emit(_ diagnostic: Diagnostic)

    /// Update the progress of an ongoing planning operation.
    func updateProgress(statusMessage: String, showInLog: Bool)
}

/// The operation which manages planning the build operation, especially communicating back to Xcode to get additional information about the targets to build.
package final class PlanningOperation: Sendable {
    /// The planning operation delegate
    let delegate: any PlanningOperationDelegate
    /// The request which initiated the planning operation.
    let request: Request
    /// A unique identifier that can remain unique even when persisted over time.  This is used, for example, to identify logs from different build operations.
    package let uuid: UUID
    /// The session this planning operation is in.
    unowned let session: Session
    /// The workspace context being planned.
    fileprivate let workspaceContext: WorkspaceContext
    /// The build request being planned.
    private let buildRequest: BuildRequest
    private let buildRequestContext: BuildRequestContext

    /// Concurrent queue used to dispatch work to the background.
    private let workQueue: SWBQueue

    init(request: Request, session: Session, workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any PlanningOperationDelegate)
    {
        self.request = request
        self.uuid = UUID()
        self.session = session
        self.workspaceContext = workspaceContext
        self.buildRequest = buildRequest
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
        self.workQueue = SWBQueue(label: "SWBBuildService.PlanningOperation.workQueue", qos: buildRequest.qos, attributes: .concurrent, autoreleaseFrequency: .workItem)
    }

    package func plan() async -> BuildPlanRequest? {
        let messageShortening = workspaceContext.userPreferences.activityTextShorteningLevel
        delegate.updateProgress(statusMessage: messageShortening == .full ? "Planning" : "Planning build", showInLog: false)

        // Compute the target dependency closure for the build request.
        if messageShortening != .full || workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.updateProgress(statusMessage: "Computing target dependency graph", showInLog: false)
        }

        let graph = await delegate.withActivity(ruleInfo: "ComputeTargetDependencyGraph", executionDescription: "Compute target dependency graph", signature: "compute_target_graph", target: nil, parentActivity: nil) { activity in
            let graph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: ActivityReportingForwardingDelegate(operation: self, activity: activity, signature: "compute_target_graph"))

            delegate.emit(diagnostic: graph.targetBuildOrderDiagnostic, for: activity, signature: "compute_target_graph")

            // Emit a log item containing the resolved dependencies for all targets being built.
            delegate.emit(diagnostic: graph.dependencyGraphDiagnostic, for: activity, signature: "compute_target_graph")

            return graph
        }

        // If there were any errors during construction of the target build graph, end planning.
        if delegate.hadErrors {
            return nil
        }

        // Handle the degenerate case of no targets. Also we don't need provisioning for the modern index-related operations.
        if graph.allTargets.isEmpty || self.buildRequest.enableIndexBuildArena {
            // We are still in a message handler, so dispatch this asynchronously to ensure the client doesn't unintentionally block the message queue.
            return BuildPlanRequest(workspaceContext: self.workspaceContext, buildRequest: self.buildRequest, buildRequestContext: self.buildRequestContext, buildGraph: graph, provisioningInputs: [:])
        }

        // We now need to request all the provisioning inputs, which we do in parallel.
        let provisioningInputs: [ConfiguredTarget: ProvisioningTaskInputs]
        do {
            provisioningInputs = try await Dictionary(uniqueKeysWithValues: withThrowingTaskGroup(of: (ConfiguredTarget, ProvisioningTaskInputs).self) { [delegate] group in
                return try await delegate.withActivity(ruleInfo: "GatherProvisioningInputs", executionDescription: "Gather provisioning inputs", signature: "gather_provisioning_inputs", target: nil, parentActivity: nil) { [delegate] activity in
                    for (index, target) in graph.allTargets.enumerated() {
                        group.addTask {
                            try _Concurrency.Task.checkCancellation()

                            // Dispatch the request for inputs.
                            let inputs = await self.getProvisioningTaskInputs(for: target)

                            if self.workspaceContext.userPreferences.enableDebugActivityLogs {
                                delegate.emit(data: Array("Received inputs for target \(target): \(inputs)\n".utf8), for: activity, signature: "gather_provisioning_inputs")
                            }

                            // Register the result.
                            let numInputs = index + 1
                            let provisioningStatus = messageShortening >= .allDynamicText ? "Provisioning \(activityMessageFractionString(numInputs, over: graph.allTargets.count))" : "Getting \(numInputs) of \(graph.allTargets.count) provisioning task inputs"
                            delegate.updateProgress(statusMessage: provisioningStatus, showInLog: false)

                            return (target, inputs)
                        }
                    }
                    return try await group.collect()
                }
            })
        } catch {
            return nil // CancellationError
        }

        if messageShortening != .full || self.workspaceContext.userPreferences.enableDebugActivityLogs {
            self.delegate.updateProgress(statusMessage: "Creating build plan request", showInLog: false)
        }

        return BuildPlanRequest(workspaceContext: self.workspaceContext, buildRequest: self.buildRequest, buildRequestContext: self.buildRequestContext, buildGraph: graph, provisioningInputs: provisioningInputs)
    }

    // MARK: Provisioning task inputs

    /// An outstanding provisioning input request.
    struct ProvisioningTaskInputRequest: Sendable {
        /// The target the request was made for.
        let configuredTarget: ConfiguredTarget

        /// The handle that was created for the settings.
        let settingsHandle: String

        /// The bundle identifier computed to pass to the client, also needed to evaluate settings in the entitlements plists in the response.
        let bundleIdentifier: String

        /// The completion block.
        let completion: @Sendable (ProvisioningTaskInputs) -> Void
    }

    /// A map of (transient) UUID strings to configured targets, tracking which configured targets we have outstanding requests from the client for provisioning task inputs.
    private let provisioningTaskInputRequests = Registry<String, ProvisioningTaskInputRequest>()

    /// Create the provisioning task inputs for a configured target.
    private func getProvisioningTaskInputs(for configuredTarget: ConfiguredTarget) async -> ProvisioningTaskInputs {
        // We only collect provisioning task inputs for standard targets.
        if let target = configuredTarget.target as? SWBCore.StandardTarget
        {
            // Create the settings and collect data we need to ship back to the client.
            let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: target)

            // Exit early if code signing is disabled, or if we don't have a valid SDK.
            guard let project = settings.project, let sdk = settings.sdk,
                  settings.globalScope.evaluate(BuiltinMacros.CODE_SIGNING_ALLOWED)
            else {
                return ProvisioningTaskInputs()
            }

            let productTypeEntitlements = (try? settings.productType?.productTypeEntitlements(settings.globalScope, platform: settings.platform, fs: workspaceContext.fs)) ?? .plDict([:])
            let entitlementsFilePath = lookupEntitlementsFilePath(from: settings.globalScope, project: project, sdk: sdk, fs: workspaceContext.fs)
            let signingCertificateIdentifier = computeSigningCertificateIdentifier(from: settings.globalScope, platform: settings.platform)

            // Evaluate build settings needed by the client.
            let sdkCanonicalName = sdk.canonicalName
            let sdkVariant = settings.globalScope.evaluate(BuiltinMacros.SDK_VARIANT)
            let signingRequiresTeam = settings.globalScope.evaluate(BuiltinMacros.CODE_SIGNING_REQUIRES_TEAM)
            let productTypeIdentifier = settings.globalScope.evaluateAsString(BuiltinMacros.PRODUCT_TYPE)
            let provisioningProfileSpecifier = settings.globalScope.evaluateAsString(BuiltinMacros.PROVISIONING_PROFILE_SPECIFIER)
            let provisioningProfileUUID = settings.globalScope.evaluateAsString(BuiltinMacros.PROVISIONING_PROFILE)
            let supportsEntitlements = settings.globalScope.evaluateAsString(BuiltinMacros.MACH_O_TYPE) == "mh_execute"
            let wantsBaseEntitlementInjection = settings.globalScope.evaluate(BuiltinMacros.CODE_SIGN_INJECT_BASE_ENTITLEMENTS)
            let entitlementsDestination = settings.globalScope.evaluate(BuiltinMacros.ENTITLEMENTS_DESTINATION)
            let localSigningStyle = settings.globalScope.evaluate(BuiltinMacros.CODE_SIGN_LOCAL_EXECUTION_IDENTITY)
            let entitlementsContentsString = settings.globalScope.evaluate(BuiltinMacros.CODE_SIGN_ENTITLEMENTS_CONTENTS)
            let enableCloudSigning = settings.globalScope.evaluate(BuiltinMacros.ENABLE_CLOUD_SIGNING)

            let provisioningProfileSupport: ProvisioningProfileSupport
            if settings.globalScope.evaluate(BuiltinMacros.PROVISIONING_PROFILE_REQUIRED) {
                provisioningProfileSupport = .required
            } else if settings.globalScope.evaluate(BuiltinMacros.PROVISIONING_PROFILE_SUPPORTED) {
                provisioningProfileSupport = .optional
            } else {
                provisioningProfileSupport = .unsupported
            }

            // Get the source data from the PIF.
            let configurationName = settings.targetConfiguration?.name ?? ""
            guard let targetSourceData = target.provisioningSourceData(for: configurationName, scope: settings.globalScope) else {
                return ProvisioningTaskInputs()
            }

            // Compute the effective bundle and team IDs
            let parsedBundleIdentifierFromInfoPlist = settings.userNamespace.parseString(targetSourceData.bundleIdentifierFromInfoPlist)
            let bundleIdentifier = computeBundleIdentifier(from: settings.globalScope, bundleIdentifierFromInfoPlist: parsedBundleIdentifierFromInfoPlist)
            let teamID = settings.globalScope.evaluate(BuiltinMacros.DEVELOPMENT_TEAM).nilIfEmpty

            func processRawEntitlements(_ rawEntitlements: PropertyListItem) -> PropertyListItem {
                // The three settings that provisioning inputs generation wants other than those in the Settings are CFBundleIdentifier, AppIdentifierPrefix and TeamIdentifierPrefix.  We have CFBundleIdentifier here, so we can evaluate it.
                // But the values of the last two are part of the provisioning inputs response, and so are not available to evaluate here.  So we preserve references to them so we can evaluate them when we get the final entitlements plists back as part of the provisioning inputs.
                let preserveReferencesToSettings = Set([BuiltinMacros.AppIdentifierPrefix])
                let parsedBundleIdentifier = settings.userNamespace.parseLiteralString(bundleIdentifier)

                // Based on the conversation from rdar://problem/40909675, the team prefix should have a trailing period (`.`), but **only** if teamID actually has a value.
                let parsedTeamIdentifierPrefix = settings.userNamespace.parseLiteralString(teamID.flatMap { $0 + "." } ?? "")

                return rawEntitlements.byEvaluatingMacros(withScope: settings.globalScope, andDictionaryKeys: true, preserveReferencesToSettings: preserveReferencesToSettings, lookup: { macro in
                    switch macro {
                    case BuiltinMacros.CFBundleIdentifier:
                        return parsedBundleIdentifier
                    case BuiltinMacros.TeamIdentifierPrefix:
                        return parsedTeamIdentifierPrefix
                    default:
                        return nil
                    }
                })
            }

            // We need to read the entitlements from CODE_SIGN_ENTITLEMENTS_CONTENTS and evaluate build settings in it, to send it to Xcode to generate the provisioning inputs.
            let entitlementsFromBuildSetting: PropertyListItem?
            if !entitlementsContentsString.isEmpty {
                if let rawEntitlementsFromBuildSetting = try? PropertyList.fromString(entitlementsContentsString) {
                    entitlementsFromBuildSetting = processRawEntitlements(rawEntitlementsFromBuildSetting)
                }
                else {
                    delegate.emit(.default, .init(behavior: .error, location: .buildSetting(name: "CODE_SIGN_ENTITLEMENTS_CONTENTS"), data: .init("The value of CODE_SIGN_ENTITLEMENTS_CONTENTS could not be parsed as entitlements")))

                    entitlementsFromBuildSetting = nil
                }
            }
            else {
                entitlementsFromBuildSetting = nil
            }

            // We need to read the entitlements file and evaluate build settings in it, to send it to Xcode to generate the provisioning inputs.
            let entitlementsFromFile: PropertyListItem?
            if let entitlementsFilePath = entitlementsFilePath {
                if let rawEntitlementsFromFile = try? PropertyList.fromPath(entitlementsFilePath, fs: workspaceContext.fs) {
                    entitlementsFromFile = processRawEntitlements(rawEntitlementsFromFile)
                }
                else {
                    // FIXME: We should report an issue if we couldn't read the file.  Though presently I think the provisioning inputs generation machinery will do that, it might be clearer to just deal with it ourselves.  However, if `CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION` is being used, the file path might point to a generated file which hasn't yet been created, and we won't be able to read it anyways.
                    entitlementsFromFile = nil
                }
            }
            else {
                entitlementsFromFile = nil
            }

            let entitlements: PropertyListItem? = {
                if let entitlementsFromFile = entitlementsFromFile, let entitlementsFromBuildSetting = entitlementsFromBuildSetting {
                    guard case .plDict(let entitlementsFromFileDictionary) = entitlementsFromFile else {
                        delegate.emit(.default, .init(behavior: .warning, location: .path(entitlementsFilePath!), data: .init("CODE_SIGN_ENTITLEMENTS references an entitlements file that is not a dictionary, ignoring")))

                        return entitlementsFromBuildSetting
                    }

                    guard case .plDict(let entitlementsFromBuildSettingDictionary) = entitlementsFromBuildSetting else {
                        delegate.emit(.default, .init(behavior: .warning, location: .buildSetting(name: "CODE_SIGN_ENTITLEMENTS_CONTENTS"), data: .init("CODE_SIGN_ENTITLEMENTS_CONTENTS contains a property list that is not a dictionary, ignoring")))

                        return entitlementsFromFile
                    }

                    return .plDict(entitlementsFromFileDictionary.addingContents(of: entitlementsFromBuildSettingDictionary))
                }
                else if let entitlementsFromFile = entitlementsFromFile {
                    return entitlementsFromFile
                }
                else if let entitlementsFromBuildSetting = entitlementsFromBuildSetting {
                    return entitlementsFromBuildSetting
                }
                else {
                    // Otherwise, we don't have any entitlements, and can just set it to nil.
                    return nil
                }
            }()

            // Create and remember a request record for this data.
            let settingsHandle = session.registerSettings(settings)
            let configuredTargetHandle = UUID().description

            // Create a message and send to the client.
            let sourceData = ProvisioningTaskInputsSourceData(configurationName: configurationName, sourceData: targetSourceData, provisioningProfileSupport: provisioningProfileSupport, provisioningProfileSpecifier: provisioningProfileSpecifier, provisioningProfileUUID: provisioningProfileUUID, bundleIdentifier: bundleIdentifier, productTypeEntitlements: productTypeEntitlements, productTypeIdentifier: productTypeIdentifier, projectEntitlementsFile: entitlementsFilePath?.str, projectEntitlements: entitlements, signingCertificateIdentifier: signingCertificateIdentifier, signingRequiresTeam: signingRequiresTeam, teamID: teamID, sdkRoot: sdkCanonicalName, sdkVariant: sdkVariant, supportsEntitlements: supportsEntitlements, wantsBaseEntitlementInjection: wantsBaseEntitlementInjection, entitlementsDestination: entitlementsDestination.rawValue, localSigningStyle: localSigningStyle, enableCloudSigning: enableCloudSigning)

            let message = GetProvisioningTaskInputsRequest(sessionHandle: session.UID, planningOperationHandle: uuid.description, targetGUID: configuredTarget.target.guid, configuredTargetHandle: configuredTargetHandle, sourceData: sourceData)

            // Create the outstanding request entry.
            return await withCheckedContinuation { continuation in
                workQueue.async {
                    self.provisioningTaskInputRequests[configuredTargetHandle] = ProvisioningTaskInputRequest(configuredTarget: configuredTarget, settingsHandle: settingsHandle, bundleIdentifier: bundleIdentifier, completion: { inputs in
                        continuation.resume(returning: inputs)
                    })

                    self.request.send(message)
                }
            }
        }
        else
        {
            // Other target classes get an empty provisioning object.
            return ProvisioningTaskInputs()
        }
    }

    /// Handle a response from the client providing provisioning task inputs for a configured target.
    func receiveProvisioningTaskInputs(_ response: ProvisioningTaskInputsResponse, _ configuredTargetUUID: String) {
        workQueue.async {
            // FIXME: Need better error handing here.  Probably if anything goes wrong then we should fail the build.
            guard let subrequest = self.provisioningTaskInputRequests.removeValue(forKey: configuredTargetUUID) else {
                fatalError("couldn't find provisioning task input request for configured target with UUID \(configuredTargetUUID)")
            }

            // Create a provisioning task inputs object from the response and pass it to the subrequest's completion block.
            // First retrieve the settings from the session.
            let settings: Settings
            do {
                settings = try self.session.settings(for: subrequest.settingsHandle)
            }
            catch let e as SessionError {
                let error: String
                switch e {
                case .noSettings(let str):
                    error = str
                case .differentWorkspace(_):
                    error = "No settings in session for handle '\(subrequest.settingsHandle)': Handle is for a different workspace"
                }
                fatalError(error)
            }
            catch {
                fatalError("no settings in session for handle '\(subrequest.settingsHandle)': Unknown error")
            }
            // Now evaluate settings in the entitlements plists we got back from the client.  This includes some settings we evaluated before sending the request because the provisioning inputs generation may add content referring to those settings beyond what we passed to it.
            let parsedBundleIdentifier = settings.userNamespace.parseLiteralString(subrequest.bundleIdentifier)
            let parsedAppIdentifierPrefix = settings.userNamespace.parseLiteralString(response.appIdentifierPrefix ?? "")
            let parsedTeamIdentifierPrefix = settings.userNamespace.parseLiteralString(response.teamIdentifierPrefix ?? "")
            let lookup: ((MacroDeclaration) -> MacroExpression?) = { macro in
                switch macro {
                case BuiltinMacros.CFBundleIdentifier:
                    return parsedBundleIdentifier
                case BuiltinMacros.AppIdentifierPrefix:
                    return parsedAppIdentifierPrefix
                case BuiltinMacros.TeamIdentifierPrefix:
                    return parsedTeamIdentifierPrefix
                default:
                    return nil
                }
            }
            let signedEntitlements = (response.signedEntitlements ?? .plDict([:])).byEvaluatingMacros(withScope: settings.globalScope, andDictionaryKeys: true, lookup: lookup)
            let simulatedEntitlements = (response.simulatedEntitlements ?? .plDict([:])).byEvaluatingMacros(withScope: settings.globalScope, andDictionaryKeys: true, lookup: lookup)
            // Finally create the inputs and pass them to the completion block.
            let inputs = ProvisioningTaskInputs(identityHash: response.identityHash, identitySerialNumber: response.identitySerialNumber, identityName: response.identityName, profileName: response.profileName, profileUUID: response.profileUUID, profilePath: (response.profilePath != nil ? Path(response.profilePath!) : nil), designatedRequirements: response.designatedRequirements, signedEntitlements: signedEntitlements, simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: response.appIdentifierPrefix, teamIdentifierPrefix: response.teamIdentifierPrefix, isEnterpriseTeam: response.isEnterpriseTeam, useSigningTool: response.useSigningTool, signingToolKeyPath: response.signingToolKeyPath, signingToolKeyID: response.signingToolKeyID, signingToolKeyIssuerID: response.signingToolKeyIssuerID, keychainPath: response.keychainPath, errors: response.errors, warnings: response.warnings)
            subrequest.completion(inputs)

            // Clean up.
            do {
                try self.session.unregisterSettings(for: subrequest.settingsHandle)
            }
            catch let e as SessionError {
                let error: String
                switch e {
                case .noSettings(let str):
                    error = str
                case .differentWorkspace(_):
                    error = "No settings to unregister in session for handle '\(subrequest.settingsHandle)': Handle is for a different workspace"
                }
                fatalError(error)
            }
            catch {
                fatalError("no settings to unregister in session for handle '\(subrequest.settingsHandle)': Unknown error")
            }
        }
    }
}

extension PlanningOperation: TargetDependencyResolverDelegate {
    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return delegate.diagnosticsEngine(for: target)
    }

    package func emit(_ diagnostic: Diagnostic) {
        delegate.emit(diagnostic)
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) {
        delegate.updateProgress(statusMessage: statusMessage, showInLog: showInLog)
    }

    package var diagnosticContext: DiagnosticContextData {
        return DiagnosticContextData(target: nil)
    }
}


extension ProvisioningTaskInputsSourceData
{
    init(configurationName: String, sourceData: ProvisioningSourceData, provisioningProfileSupport: ProvisioningProfileSupport, provisioningProfileSpecifier: String, provisioningProfileUUID: String, bundleIdentifier: String, productTypeEntitlements: PropertyListItem, productTypeIdentifier: String, projectEntitlementsFile: String?, projectEntitlements: PropertyListItem?, signingCertificateIdentifier: String, signingRequiresTeam: Bool, teamID: String?, sdkRoot: String, sdkVariant: String?, supportsEntitlements: Bool, wantsBaseEntitlementInjection: Bool, entitlementsDestination: String, localSigningStyle: String, enableCloudSigning: Bool)
    {
        self.init(configurationName: configurationName, provisioningProfileSupport: provisioningProfileSupport, provisioningProfileSpecifier: provisioningProfileSpecifier, provisioningProfileUUID: provisioningProfileUUID, provisioningStyle: sourceData.provisioningStyle, teamID: teamID, bundleIdentifier: bundleIdentifier, productTypeEntitlements: productTypeEntitlements, productTypeIdentifier: productTypeIdentifier, projectEntitlementsFile: projectEntitlementsFile, projectEntitlements: projectEntitlements, signingCertificateIdentifier: signingCertificateIdentifier, signingRequiresTeam: signingRequiresTeam, sdkRoot: sdkRoot, sdkVariant: sdkVariant, supportsEntitlements: supportsEntitlements, wantsBaseEntitlementInjection: wantsBaseEntitlementInjection, entitlementsDestination: entitlementsDestination, localSigningStyle: localSigningStyle, enableCloudSigning: enableCloudSigning)
    }
}

/// A delegate to inject diagnostics for an activity into the activity itself instead of as global diagnostics
fileprivate final class ActivityReportingForwardingDelegate: TargetDependencyResolverDelegate {
    let operation: PlanningOperation
    let activity: ActivityID
    let signature: ByteString

    init(operation: PlanningOperation, activity: ActivityID, signature: ByteString) {
        self.operation = operation
        self.activity = activity
        self.signature = signature
    }

    var delegate: any PlanningOperationDelegate {
        operation.delegate
    }

    func updateProgress(statusMessage: String, showInLog: Bool) {
        delegate.updateProgress(statusMessage: statusMessage, showInLog: showInLog)
    }

    var diagnosticContext: SWBCore.DiagnosticContextData {
        delegate.diagnosticContext
    }

    func diagnosticsEngine(for target: SWBCore.ConfiguredTarget?) -> SWBCore.DiagnosticProducingDelegateProtocolPrivate<SWBUtil.DiagnosticsEngine> {
        delegate.diagnosticsEngine(for: target)
    }

    func emit(_ context: TargetDiagnosticContext, _ diagnostic: Diagnostic) {
        if case .default = context {
            delegate.emit(diagnostic: diagnostic, for: activity, signature: signature)
        } else {
            delegate.emit(context, diagnostic)
        }
    }
}
