#[[
This source file is part of the Swift open source project

Copyright (c) 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBBuildServerProtocol
  AsyncQueue.swift
  AsyncUtils.swift
  BuildShutdownRequest.swift
  BuildSystemMessageDependencyTracker.swift
  BuildTarget.swift
  BuildTargetPrepareRequest.swift
  BuildTargetSourcesRequest.swift
  CancelRequestNotification.swift
  Connection.swift
  CreateWorkDoneProgressRequest.swift
  CustomCodable.swift
  DidChangeWatchedFilesNotification.swift
  DocumentURI.swift
  Error.swift
  FileEvent.swift
  FileSystemWatcher.swift
  InitializeBuildRequest.swift
  Language.swift
  LocalConnection.swift
  Location.swift
  LogMessageNotification.swift
  LSPAny.swift
  Message.swift
  MessageRegistry.swift
  Messages.swift
  MessageType.swift
  MillisecondsSince1970Date.swift
  OnBuildExitNotification.swift
  OnBuildInitializedNotification.swift
  OnBuildLogMessageNotification.swift
  OnBuildTargetDidChangeNotification.swift
  OnWatchedFilesDidChangeNotification.swift
  Position.swift
  PositionRange.swift
  ProgressToken.swift
  QueueBasedMessageHandler.swift
  RequestAndReply.swift
  RequestID.swift
  ResponseError+Init.swift
  StatusCode.swift
  TaskFinishNotification.swift
  TaskId.swift
  TaskProgressNotification.swift
  TaskStartNotification.swift
  TextDocumentIdentifier.swift
  TextDocumentSourceKitOptionsRequest.swift
  WindowMessageType.swift
  WorkspaceBuildTargetsRequest.swift
  WorkspaceWaitForBuildSystemUpdates.swift)
set_target_properties(SWBBuildServerProtocol PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBBuildServerProtocol PUBLIC
  SWBUtil)

set_target_properties(SWBBuildServerProtocol PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBBuildServerProtocol)

install(TARGETS SWBBuildServerProtocol
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
