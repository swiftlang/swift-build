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

import Foundation
import SWBProtocol
import SWBUtil
import Testing

@Suite fileprivate struct MessageSerializationTests {
    let params: BuildParametersMessagePayload
    let payload: BuildRequestMessagePayload

    init() {
        params = BuildParametersMessagePayload(
            action: "build",
            configuration: "Debug",
            activeRunDestination: RunDestinationInfo(
                platform: "osOS",
                sdk: "osos",
                sdkVariant: "x",
                targetArchitecture: "arm128",
                supportedArchitectures: ["arm128"],
                disableOnlyActiveArch: true,
                hostTargetedPlatform: nil
            ),
            activeArchitecture: "arm128",
            arenaInfo: ArenaInfo(
                derivedDataPath: Path("/tmp"),
                buildProductsPath: Path("/tmp/build"),
                buildIntermediatesPath: Path("/tmp/int"),
                pchPath: Path("/tmp/pch"),
                indexRegularBuildProductsPath: nil,
                indexRegularBuildIntermediatesPath: nil,
                indexPCHPath: Path("/tmp/pch-index"),
                indexDataStoreFolderPath: Path("/tmp/ds"),
                indexEnableDataStore: true
            ),
            overrides: SettingsOverridesMessagePayload(
                synthesized: ["foo": "bar"],
                commandLine: ["baz": "blah"],
                commandLineConfigPath: Path("/path/to/cl.xcconfig"),
                commandLineConfig: ["what": "is this"],
                environmentConfigPath: Path("/path/to/env.xcconfig"),
                environmentConfig: ["this": "too"],
                toolchainOverride: "thats enough"
            )
        )

        payload = BuildRequestMessagePayload(parameters: params, configuredTargets: [ConfiguredTargetMessagePayload(guid: "some other guid", parameters: params)], dependencyScope: .workspace, continueBuildingAfterErrors: true, hideShellScriptEnvironment: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: true, showNonLoggedProgress: false, recordBuildBacktraces: nil, generatePrecompiledModulesReport: nil, buildPlanDiagnosticsDirPath: Path("/tmp/foobar"), buildCommand: .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: false), schemeCommand: .profile, containerPath: Path("/tmp/foobar.xcodeproj"), buildDescriptionID: nil, qos: nil, jsonRepresentation: Data())
    }

    @Test func basicMessagesRoundTrip() throws {
        assertMsgPackMessageRoundTrip(PingRequest())
        assertMsgPackMessageRoundTrip(PingResponse())
        assertMsgPackMessageRoundTrip(SetConfigItemRequest(key: "MyKey", value: "MyValue"))
        assertMsgPackMessageRoundTrip(ClearAllCachesRequest())
        assertMsgPackMessageRoundTrip(GetPlatformsRequest(sessionHandle: "theSession", commandLine: []))
        assertMsgPackMessageRoundTrip(GetSDKsRequest(sessionHandle: "theSession", commandLine: []))
        assertMsgPackMessageRoundTrip(GetSpecsRequest(sessionHandle: "theSession", commandLine: []))
        assertMsgPackMessageRoundTrip(GetStatisticsRequest())
        assertMsgPackMessageRoundTrip(GetToolchainsRequest(sessionHandle: "theSession", commandLine: []))
        assertMsgPackMessageRoundTrip(DeveloperPathRequest(sessionHandle: "theSession"))
        assertMsgPackMessageRoundTrip(ExecuteCommandLineToolRequest(commandLine: ["echo foo"], workingDirectory: .root, developerPath: Path("/Application/Xcode.app/Contents/Developer"), replyChannel: 42))
        assertMsgPackMessageRoundTrip(GetBuildSettingsDescriptionRequest(sessionHandle: "theSession", commandLine: []))
        assertMsgPackMessageRoundTrip(CreateSessionRequest(name: "coolSession", developerPath: Path("/Application/Xcode.app/Contents/Developer"), cachePath: Path.root.join("tmp"), inferiorProductsPath: Path("/Builds"), environment: [:]))
        assertMsgPackMessageRoundTrip(SetSessionSystemInfoRequest(sessionHandle: "theSession", operatingSystemVersion: Version(11, 1, 3), productBuildVersion: "25A573", nativeArchitecture: "arm64"))
        assertMsgPackMessageRoundTrip(SetSessionUserInfoRequest(sessionHandle: "theSession", user: "mobile", group: "mobile", uid: 501, gid: 99, home: "/root", processEnvironment: ["HOME": "/root"], buildSystemEnvironment: ["SRCROOT": "/"]))
        assertMsgPackMessageRoundTrip(SetSessionUserPreferencesRequest(sessionHandle: "theSession", enableDebugActivityLogs: true, enableBuildDebugging: true, enableBuildSystemCaching: true, activityTextShorteningLevel: .default, usePerConfigurationBuildLocations: nil))
        assertMsgPackMessageRoundTrip(ListSessionsRequest())
        assertMsgPackMessageRoundTrip(ListSessionsResponse(sessions: ["theSession": .init(name: "itsGreat", activeBuildCount: 0, activeNormalBuildCount: 0, activeIndexBuildCount: 0)]))
        assertMsgPackMessageRoundTrip(DeleteSessionRequest(sessionHandle: "theSession"))
        assertMsgPackMessageRoundTrip(SetSessionWorkspaceContainerPathRequest(sessionHandle: "theSession", containerPath: "/path/to/my.xcworkspace"))
        assertMsgPackMessageRoundTrip(SetSessionPIFRequest(sessionHandle: "theSession", pifContents: [0, 1, 2, 3]))
        assertMsgPackMessageRoundTrip(TransferSessionPIFRequest(sessionHandle: "theSession", workspaceSignature: "W1"))
        assertMsgPackMessageRoundTrip(TransferSessionPIFResponse(missingObjects: [])) { originalObject, deserializedObject in
            #expect(originalObject.isComplete == true)
            #expect(originalObject.isComplete == deserializedObject.isComplete)
        }
        assertMsgPackMessageRoundTrip(TransferSessionPIFResponse(missingObjects: [TransferSessionPIFResponse.MissingObject(type: .workspace, signature: "W1")])) { originalObject, deserializedObject in
            #expect(originalObject.isComplete == false)
            #expect(originalObject.isComplete == deserializedObject.isComplete)
        }
        assertMsgPackMessageRoundTrip(TransferSessionPIFObjectsLegacyRequest(sessionHandle: "theSession", objects: [[0, 1], [2, 3]]))
        assertMsgPackMessageRoundTrip(TransferSessionPIFObjectsRequest(sessionHandle: "theSession", objects: [TransferSessionPIFObjectsRequest.ObjectData(pifType: .workspace, signature: "bar", data: "baz")]))
        assertMsgPackMessageRoundTrip(AuditSessionPIFRequest(sessionHandle: "theSession", pifContents: [4, 7, 9, 13]))
        assertMsgPackMessageRoundTrip(IncrementalPIFLookupFailureRequest(sessionHandle: "theSession", diagnostic: "everything went wrong"))
        assertMsgPackMessageRoundTrip(WorkspaceInfoRequest(sessionHandle: "theSession"))
        assertMsgPackMessageRoundTrip(WorkspaceInfoResponse(sessionHandle: "theSession", workspaceInfo: .init(targetInfos: [.init(guid: "theGuid", targetName: "aTarget", projectName: "aProject")])))

        assertMsgPackMessageRoundTrip(ErrorResponse("everything went wrong"))
        assertMsgPackMessageRoundTrip(BoolResponse(true))
        assertMsgPackMessageRoundTrip(BoolResponse(false))
        assertMsgPackMessageRoundTrip(StringResponse(""))
        assertMsgPackMessageRoundTrip(StringResponse("hello world"))
        assertMsgPackRoundTrip(CreateXCFrameworkRequest(developerPath: Path("/Applications/Xcode.app/Contents/Developer"), commandLine: ["createXCFramework", "-framework", "fpath1", "-output", "opath"], currentWorkingDirectory: Path.root.join("tmp")))
    }

    @Test func clientExchangeMessagesRoundTrip() {
        assertMsgPackMessageRoundTrip(ExternalToolExecutionRequest(sessionHandle: "theSession", exchangeHandle: "handle", commandLine: ["echo", "foo"], workingDirectory: "/foo", environment: ["FOO": "BAR"]))

        assertMsgPackMessageRoundTrip(ExternalToolExecutionResponse(sessionHandle: "theSession", exchangeHandle: "handle", value: .success(.result(status: .exit(1), stdout: Data("foo".utf8), stderr: Data("bar".utf8)))))
        assertMsgPackMessageRoundTrip(ExternalToolExecutionResponse(sessionHandle: "theSession", exchangeHandle: "handle", value: .failure(StubError.error("broken!"))))

        do {
            let tag = 2 as Int

            // Serialize an invalid ExternalToolExecutionResponse
            let serializer = MsgPackSerializer()
            serializer.serializeAggregate(3) {
                serializer.serialize("theSession")
                serializer.serialize("handle")

                serializer.serializeAggregate(2) {
                    serializer.serialize(tag)
                    serializer.serializeNil()
                }
            }

            // Make sure we get the expected error

            do {
                let deserializer = MsgPackDeserializer(serializer.byteString)
                #expect { try deserializer.deserialize() as ExternalToolExecutionResponse } throws: { error in
                    (error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Expected 0 or 1 for Result tag, but got \(tag)").errorString
                }
            }
        }
    }

    @Test func indexingMessagesRoundTrip() {
        assertMsgPackMessageRoundTrip(IndexingFileSettingsRequest(sessionHandle: "theSession", responseChannel: 42, request: payload, targetID: "some id", filePath: "some file", outputPathOnly: false))
        assertMsgPackMessageRoundTrip(IndexingFileSettingsRequest(sessionHandle: "theSession", responseChannel: 42, request: payload, targetID: "some id", filePath: nil, outputPathOnly: true))
        assertMsgPackMessageRoundTrip(IndexingFileSettingsResponse(targetID: "the target ID", data: ByteString([0, 1, 4])))
        assertMsgPackMessageRoundTrip(IndexingHeaderInfoRequest(sessionHandle: "theSession", responseChannel: 42, request: payload, targetID: "some id"))
        assertMsgPackMessageRoundTrip(IndexingHeaderInfoResponse(targetID: "the target ID", productName: "theProduct", copiedPathMap: ["/foo/bar.h": "/baz/quux.h"]))
    }

    @Test func previewInfoMessagesRoundTrip() {
        assertMsgPackMessageRoundTrip(PreviewInfoRequest(sessionHandle: "theSession", responseChannel: 42, request: payload, targetID: "some id", sourceFile: Path("/best"), thunkVariantSuffix: "best"))
        assertMsgPackMessageRoundTrip(PreviewInfoResponse(targetIDs: ["the target ID"], output: [PreviewInfoMessagePayload(context: .init(sdkRoot: "macosx", sdkVariant: "default", buildVariant: "default", architecture: "i386", pifGUID: "xyz"), kind: .thunkInfo(.init(compileCommandLine: ["swiftc"], linkCommandLine: ["ld"], thunkSourceFile: Path("/best.swift"), thunkObjectFile: Path("/best.o"), thunkLibrary: Path("/best.dylib"))))]))
    }

    @Test func planningOperationMessages() {
        assertMsgPackMessageRoundTrip(PlanningOperationWillStart(sessionHandle: "random handle", planningOperationHandle: "random other handle"))
        assertMsgPackMessageRoundTrip(PlanningOperationDidFinish(sessionHandle: "dog", planningOperationHandle: "cat"))
        let sourceData = ProvisioningTaskInputsSourceData(configurationName: "i am running", provisioningProfileSupport: .unsupported, provisioningProfileSpecifier: "out of ideas", provisioningProfileUUID: "for", provisioningStyle: .automatic, teamID: "good test", bundleIdentifier: "string names", productTypeEntitlements: .plDict(["get-task-allow": .plBool(true)]), productTypeIdentifier: "going to use", projectEntitlementsFile: "sentence fragments", projectEntitlements: .plString("like this"), signingCertificateIdentifier: "until i run", signingRequiresTeam: true, sdkRoot: "out of ideas", sdkVariant: "cool", supportsEntitlements: true, wantsBaseEntitlementInjection: false, entitlementsDestination: "again", localSigningStyle: "new style")
        assertMsgPackMessageRoundTrip(GetProvisioningTaskInputsRequest(sessionHandle: "theSession", planningOperationHandle: "blah", targetGUID: "guid8363939", configuredTargetHandle: "myapp", sourceData: sourceData))
        assertMsgPackMessageRoundTrip(ProvisioningTaskInputsResponse(sessionHandle: "theSession", planningOperationHandle: "more of these", configuredTargetHandle: "annoying strings", identityHash: "that are hard to", identitySerialNumber: "um", identityName: "think up names for", profileName: "but i will", profileUUID: "keep trying", profilePath: "until this target", designatedRequirements: "has 100%", signedEntitlements: .plString("test coverage"), simulatedEntitlements: .plString("which will prevent"), appIdentifierPrefix: "errors from occurring", teamIdentifierPrefix: "in our codebase", isEnterpriseTeam: false, useSigningTool: false, signingToolKeyPath: "thingamajig", signingToolKeyID: "whosawhatsit", signingToolKeyIssuerID: "woozlewozle", keychainPath: "and uhh", errors: [["something": "i don't know"]], warnings: ["warning: don't do that"]))
    }

    @Test func macroEvaluationMessages() {
        assertMsgPackMessageRoundTrip(CreateMacroEvaluationScopeRequest(sessionHandle: "theSession", level: .project("this ones cool"), buildParameters: params))
        assertMsgPackMessageRoundTrip(CreateMacroEvaluationScopeRequest(sessionHandle: "aOtherSession", level: .target("this is cool too"), buildParameters: params))
        assertMsgPackMessageRoundTrip(DiscardMacroEvaluationScope(sessionHandle: "theHandle", settingsHandle: "theOtherHandle"))

        assertMsgPackMessageRoundTrip(MacroEvaluationRequest(sessionHandle: "theHandle", context: .settingsHandle("theOtherHandle"), request: .macro("ARCHS"), overrides: ["FOO": "BAR"], resultType: .string))
        assertMsgPackMessageRoundTrip(MacroEvaluationRequest(sessionHandle: "theHandle", context: .settingsHandle("theOtherHandle"), request: .stringExpression("BLARGH"), overrides: ["FOO": "BAR"], resultType: .string))
        assertMsgPackMessageRoundTrip(MacroEvaluationRequest(sessionHandle: "theHandle", context: .settingsHandle("theOtherHandle"), request: .stringListExpression(["THINGIES"]), overrides: ["FOO": "BAR"], resultType: .stringList))
        assertMsgPackMessageRoundTrip(MacroEvaluationRequest(sessionHandle: "theHandle", context: .settingsHandle("theOtherHandle"), request: .stringExpressionArray(["WHATS_THIS"]), overrides: ["FOO": "BAR"], resultType: .stringList))

        assertMsgPackMessageRoundTrip(MacroEvaluationResponse(result: .string("x86_64")))
        assertMsgPackMessageRoundTrip(MacroEvaluationResponse(result: .stringList(["x86_64", "i386"])))
        assertMsgPackMessageRoundTrip(MacroEvaluationResponse(result: .error("it all broke")))
    }

    @Test func buildOperationMessages() {
        assertMsgPackMessageRoundTrip(CreateBuildRequest(sessionHandle: "thesession", responseChannel: 59, request: payload, onlyCreateBuildDescription: false))
        assertMsgPackMessageRoundTrip(BuildStartRequest(sessionHandle: "seshun", id: 52))
        assertMsgPackMessageRoundTrip(BuildCancelRequest(sessionHandle: "wow", id: 3209))
        assertMsgPackMessageRoundTrip(BuildCreated(id: 8936))
        assertMsgPackMessageRoundTrip(BuildOperationReportBuildDescription(buildDescriptionID: "<build-description-id>"))
        assertMsgPackMessageRoundTrip(BuildOperationStarted(id: 3589))
        assertMsgPackMessageRoundTrip(BuildOperationReportPathMap(copiedPathMap: ["foo": "bar"], generatedFilesPathMap: ["baz": "whats placeholder #4?"]))
        assertMsgPackMessageRoundTrip(BuildOperationEnded(id: 6389, status: .succeeded))
        assertMsgPackMessageRoundTrip(BuildOperationEnded(id: 984, status: .cancelled))
        assertMsgPackMessageRoundTrip(BuildOperationEnded(id: 290, status: .failed))
        assertMsgPackMessageRoundTrip(BuildOperationTargetUpToDate(guid: "uuid"))
        assertMsgPackMessageRoundTrip(BuildOperationTargetStarted(id: 359, guid: "how long is a string?", info: BuildOperationTargetInfo(name: "door", type: .standard, projectInfo: BuildOperationProjectInfo(name: "there should be a magic button to automatically generate placeholder strings for unit tests", path: "/foo/foo.xcodeproj", isPackage: false, isNameUniqueInWorkspace: true), configurationName: "at this point i'm just", configurationIsDefault: true, sdkCanonicalName: "naming things in my house")))
        assertMsgPackMessageRoundTrip(BuildOperationTargetEnded(id: 3506))
        assertMsgPackMessageRoundTrip(BuildOperationTaskUpToDate(signature: .activitySignature(ByteString([5, 39, 9])), targetID: 25, parentID: 30))
        assertMsgPackMessageRoundTrip(BuildOperationTaskStarted(id: 638, targetID: 583, parentID: 5380, info: BuildOperationTaskInfo(taskName: "a task", signature: .taskIdentifier(ByteString([83, 80])), ruleInfo: "doing stuff", executionDescription: "things are being done", commandLineDisplayString: "/usr/bin/do things 'that are useful'", interestingPath: .root, serializedDiagnosticsPaths: [Path("/root")])))
        assertMsgPackMessageRoundTrip(BuildOperationTaskEnded(id: 296, signature: .taskIdentifier("task-id"), status: .succeeded, signalled: true, metrics: nil))
        assertMsgPackMessageRoundTrip(BuildOperationProgressUpdated(targetName: "tar get", statusMessage: "sta tus", percentComplete: 6793.36, showInLog: true))
        assertMsgPackMessageRoundTrip(BuildOperationPreparationCompleted())
        assertMsgPackMessageRoundTrip(BuildOperationConsoleOutputEmitted(data: [7, 8, 8]))
        assertMsgPackMessageRoundTrip(BuildOperationConsoleOutputEmitted(data: [1, 93, 8, 8], targetID: 24))
        assertMsgPackMessageRoundTrip(BuildOperationConsoleOutputEmitted(data: [4, 9, 8, 22], taskID: 13, taskSignature: .activitySignature("activity-sig")))
        assertMsgPackMessageRoundTrip(BuildOperationDiagnosticEmitted(kind: .error, location: .path(Path("/foo"), line: 12, column: 288), message: "something went wrong", sourceRanges: [], fixIts: [], childDiagnostics: []))
        assertMsgPackMessageRoundTrip(BuildOperationDiagnosticEmitted(kind: .error, location: .path(Path("/foo"), line: 12, column: 288), message: "something went wrong", locationContext: .target(targetID: 42), sourceRanges: [], fixIts: [], childDiagnostics: []))
        assertMsgPackMessageRoundTrip(BuildOperationDiagnosticEmitted(kind: .error, location: .path(Path("/foo"), line: 12, column: 288), message: "something went wrong", locationContext: .task(taskID: 42, taskSignature: .taskIdentifier("task-id"), targetID: 42), appendToOutputStream: true, sourceRanges: [], fixIts: [], childDiagnostics: []))
        assertMsgPackMessageRoundTrip(BuildOperationDiagnosticEmitted(kind: .error, location: .path(Path("/foo"), line: 12, column: 288), message: "something went wrong", locationContext: .globalTask(taskID: 42, taskSignature: .taskIdentifier("task-id-2")), appendToOutputStream: true, sourceRanges: [], fixIts: [], childDiagnostics: []))

        #expect(BuildOperationDiagnosticEmitted.Kind.note.description == "note")
        #expect(BuildOperationDiagnosticEmitted.Kind.warning.description == "warning")
        #expect(BuildOperationDiagnosticEmitted.Kind.error.description == "error")
    }

    @Test func IPCMessageSerialization() {
        #expect(throws: (any Error).self) { try MsgPackDeserializer(ByteString([])).deserialize() as IPCMessage }
        let serializer = MsgPackSerializer()
        serializer.serialize(false)
        #expect(throws: (any Error).self) { try MsgPackDeserializer(serializer.byteString).deserialize() as IPCMessage }
        #expect(throws: (any Error).self) { try MsgPackDeserializer(ByteString([UInt8.max])).deserialize() as IPCMessage }
        #expect(throws: (any Error).self) { try MsgPackDeserializer(ByteString([0xd9, 0xc3, 0x28])).deserialize() as IPCMessage }
        #expect(throws: (any Error).self) { try IPCMessage(from: MsgPackDeserializer(ByteString([UInt8.max]))) }

        do {
            let serializer = MsgPackSerializer()
            serializer.serialize("this message does not exist")

            // Make sure we get our customized error message "unexpected IPC message" when we find an unrecognized message name
            let deserializer = MsgPackDeserializer(serializer.byteString)
            #expect { try deserializer.deserialize() as IPCMessage } throws: { error in
                ((error as? DeserializerError)?.errorString == DeserializerError.incorrectType("unexpected IPC message: `this message does not exist`").errorString)
            }
        }
    }

    private func serializationRoundTrip<T: Serializable>(_ value: T) throws -> T {
        let serializer = MsgPackSerializer()
        serializer.serialize(value)
        let deserializer = MsgPackDeserializer(serializer.byteString)
        return try deserializer.deserialize() as T
    }

    @Test func projectPlannerTypesSerialization() throws {
        let destinationInfo = DestinationInfo(platformName: "iphoneos", isSimulator: false)
        #expect(try destinationInfo == serializationRoundTrip(destinationInfo))
        let productInfo = ProductInfo(displayName: "testProduct", identifier: "123456", supportedDestinations: [destinationInfo])
        #expect(try productInfo == serializationRoundTrip(productInfo))
        let testPlanInfo = TestPlanInfo(displayName: "plan")
        #expect(try testPlanInfo == serializationRoundTrip(testPlanInfo))
        let actionInfo = ActionInfo(configurationName: "Debug", products: [productInfo], testPlans: [testPlanInfo])
        #expect(try actionInfo == serializationRoundTrip(actionInfo))

        let schemeDescription = SchemeDescription(name: "best", disambiguatedName: "best", isShared: true, isAutogenerated: true, actions: ActionsInfo(analyze: actionInfo, archive: actionInfo, profile: actionInfo, run: actionInfo, test: actionInfo))
        #expect(try schemeDescription == serializationRoundTrip(schemeDescription))

        let productDescription = try ProductDescription(displayName: "Product", productName: "product", identifier: "123456", productType: .app, dependencies: nil, bundleIdentifier: "com.apple.product", targetedDeviceFamilies: [.appleTV, .iPad], deploymentTarget: Version("13.0"), marketingVersion: "1.0", buildVersion: "1.0", codesign: .manual, team: "best-team", infoPlistPath: "/Info.plist", iconPath: "/Icon.png")
        #expect(try productDescription == serializationRoundTrip(productDescription))

        let productTupleDescription = ProductTupleDescription(displayName: "Product", productName: "product", productType: .app, identifier: "123456", team: nil, bundleIdentifier: "com.apple.product", destination: destinationInfo, containingSchemes: ["a", "b", "c"], iconPath: "/Icon.png")
        #expect(try productTupleDescription == serializationRoundTrip(productTupleDescription))
    }
}

fileprivate func assertMsgPackRoundTrip<T>(_ objectExpression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation, body: ((T, T) throws -> Void)? = nil) rethrows where T : Equatable & Serializable {
    let object = try objectExpression()
    let serializer = MsgPackSerializer()
    serializer.serialize(object)
    #expect(throws: Never.self, sourceLocation: sourceLocation) {
        #expect(try MsgPackDeserializer(serializer.byteString).deserialize() as T == object, sourceLocation: sourceLocation)
        try body?(object, try MsgPackDeserializer(serializer.byteString).deserialize() as T)
    }
}

fileprivate func assertMsgPackMessageRoundTrip<T>(_ objectExpression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation, body: ((T, T) throws -> Void)? = nil) rethrows where T : Message & Equatable & Serializable {
    try assertMsgPackRoundTrip(objectExpression(), sourceLocation: sourceLocation, body: body)
    let ipcObject = IPCMessage(try objectExpression())
    let ipcSerializer = MsgPackSerializer()
    ipcSerializer.serialize(ipcObject)
    #expect(throws: Never.self, sourceLocation: sourceLocation) {
        let msg = try (MsgPackDeserializer(ipcSerializer.byteString).deserialize() as IPCMessage).message as? T
        #expect(msg == ipcObject.message as? T, sourceLocation: sourceLocation)
    }
}
