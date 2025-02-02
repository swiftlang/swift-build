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

public import SWBUtil
#if os(Windows)
private import SWBLibc
#else
public import SWBLibc
#endif

// Re-export all APIs from llbuild bindings.
@_exported public import llbuild

#if !LLBUILD_FRAMEWORK
@_exported public import llbuildSwift
#endif

// Filesystem adaptors for SWBLLBuild.FileSystem.
extension SWBUtil.FileInfo: SWBLLBuild.FileInfo {}

public final class FileSystemImpl: FileSystem {

    /// The underlying FSProxy instance.
    private let fs: any FSProxy

    public init(_ fs: any FSProxy) {
        self.fs = fs
    }

    public func read(_ pathString: String) throws -> [UInt8] {
        let path = Path(pathString)
        if !path.isAbsolute {
            throw StubError.error("llbuild: path '\(path.str)' must be absolute")
        }
        return try fs.read(path).bytes
    }

    public func getFileInfo(_ pathString: String) throws -> any SWBLLBuild.FileInfo {
        let path = Path(pathString)
        if !path.isAbsolute {
            throw StubError.error("llbuild: path '\(path.str)' must be absolute")
        }
        return try fs.getFileInfo(path)
    }
}

public enum BuildValueKind: UInt32 {
    /// An invalid value, for sentinel purposes.
    case invalid = 0
    /// A value produced by a virtual input.
    case virtualInput = 1
    /// A value produced by an existing input file.
    case existingInput = 2
    /// A value produced by a missing input file.
    case missingInput = 3
    /// The contents of a directory.
    case directoryContents = 4
    /// The signature of a directories contents.
    case directoryTreeSignature = 5
    /// The signature of a directories structure.
    case directoryTreeStructureSignature = 6
    /// A value produced by stale file removal.
    case staleFileRemoval = 7
    /// A value produced by a command which succeeded, but whose output was missing.
    case missingOutput = 8
    /// A value for a produced output whose command failed or was cancelled.
    case failedInput = 9
    /// A value produced by a successful command.
    case successfulCommand = 10
    /// A value produced by a failing command.
    case failedCommand = 11
    /// A value produced by a command which was skipped because one of its dependencies failed.
    case propagatedFailureCommand = 12
    /// A value produced by a command which was cancelled.
    case cancelledCommand = 13
    /// A value produced by a command which was skipped.
    case skippedCommand = 14
    /// Sentinel value representing the result of "building" a top-level target.
    case target = 15
    /// The filtered contents of a directory.
    case filteredDirectoryContents = 16
    /// A value produced by a successful command with an output signature.
    case successfulCommandWithOutputSignature = 17

    public init?(_ kind: llbuild.BuildValueKind) {
        self.init(rawValue: UInt32(kind.rawValue))
    }

    public var isFailed: Bool {
        [
            .failedCommand,
            .propagatedFailureCommand,
            .missingInput,
            .failedInput,
        ]
        .contains(self)
    }
}

extension llbuild_pid_t {
    public static var invalid: Self {
        #if os(Windows)
        INVALID_HANDLE_VALUE
        #else
        -1
        #endif
    }
}

extension llbuild_pid_t {
    public var pid: pid_t {
        #if os(Windows)
        return Int32(GetProcessId(self))
        #else
        return self
        #endif
    }
}
