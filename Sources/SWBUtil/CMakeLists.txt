#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBUtil
  Architecture.swift
  ArgumentSplitting.swift
  Array.swift
  AsyncCache.swift
  AsyncFlatteningSequence.swift
  AsyncIteratorProtocol.swift
  AsyncLock.swift
  AsyncOperationQueue.swift
  AsyncSingleValueCache.swift
  AsyncStreamController.swift
  ByteString.swift
  Cache.swift
  Collection.swift
  CountedSet.swift
  CSV.swift
  Debugger.swift
  DependencyInfo.swift
  DiagnosticsEngine.swift
  Dictionary.swift
  Diff.swift
  Dispatch+Async.swift
  Duration.swift
  ElapsedTimer.swift
  EmptyState.swift
  Environment.swift
  EnvironmentKey.swift
  EnvironmentHelpers.swift
  Error.swift
  FileHandle+Async.swift
  FilesSignature.swift
  fnmatch.swift
  FSProxy.swift
  GraphAlgorithms.swift
  HashContext.swift
  Headermap.swift
  HeavyCache.swift
  Int.swift
  InterningArena.swift
  IO.swift
  JSONEncoder.swift
  KeyValueStorage.swift
  LazyCache.swift
  Library.swift
  LineReader.swift
  Lock.swift
  MachO.swift
  Math.swift
  Misc+Async.swift
  Misc.swift
  MsgPack.swift
  MsgPackSerialization.swift
  NamedTemporaryDirectory.swift
  Optional.swift
  OrderedDictionary.swift
  OrderedSet.swift
  OSLog.swift
  OutputByteStream.swift
  Pair.swift
  Path.swift
  PathWindows.swift
  PbxCp.swift
  PluginManager.swift
  PluginManagerCommon.swift
  POSIX.swift
  Process+Async.swift
  Process.swift
  ProcessInfo.swift
  Promise.swift
  PropertyList.swift
  Queue.swift
  RateLimiter.swift
  Ref.swift
  RegEx.swift
  Registry.swift
  ResponseFiles.swift
  Result.swift
  ScopedKeepAliveCache.swift
  Serialization.swift
  Signatures.swift
  Static.swift
  Statistics.swift
  String.swift
  SWBDispatch.swift
  TAPIFileList.swift
  UniqueSerialization.swift
  UnsafeSendableDelayedInitializationWrapper.swift
  URL.swift
  UserDefaults.swift
  Version.swift
  VFS.swift
  WaitCondition.swift
  WeakRef.swift
  Win32Error.swift
  XCBuildDataArchive.swift
  Xcode.swift)
set_target_properties(SWBUtil PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SWBUtil PUBLIC
  SWBCSupport
  SWBLibc
  ArgumentParser
  $<$<NOT:$<PLATFORM_ID:Darwin>>:SwiftSystem::SystemPackage>)
