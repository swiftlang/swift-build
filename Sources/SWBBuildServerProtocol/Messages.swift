//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

fileprivate let requestTypes: [any _RequestType.Type] = [
  BuildShutdownRequest.self,
  BuildTargetPrepareRequest.self,
  BuildTargetSourcesRequest.self,
  CreateWorkDoneProgressRequest.self,
  InitializeBuildRequest.self,
  TextDocumentSourceKitOptionsRequest.self,
  WorkspaceBuildTargetsRequest.self,
  WorkspaceWaitForBuildSystemUpdatesRequest.self,
]

fileprivate let notificationTypes: [any NotificationType.Type] = [
  CancelRequestNotification.self,
  OnBuildExitNotification.self,
  OnBuildInitializedNotification.self,
  OnBuildLogMessageNotification.self,
  OnBuildTargetDidChangeNotification.self,
  OnWatchedFilesDidChangeNotification.self,
  TaskFinishNotification.self,
  TaskProgressNotification.self,
  TaskStartNotification.self,
]

public let bspRegistry = MessageRegistry(requests: requestTypes, notifications: notificationTypes)

public struct VoidResponse: ResponseType, Hashable {
  public init() {}
}

extension Optional: MessageType where Wrapped: MessageType {}
extension Optional: ResponseType where Wrapped: ResponseType {}

extension Array: MessageType where Element: MessageType {}
extension Array: ResponseType where Element: ResponseType {}
