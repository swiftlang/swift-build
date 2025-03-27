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

/// Delegation protocol for client-side things that relate to collecting preview information.
public protocol SWBPreviewDelegate: SWBPlanningOperationDelegate {
}

public protocol SWBPreviewInfoContext: Equatable, Sendable {
    var sdkRoot: String { get }
    var sdkVariant: String? { get }
    var buildVariant: String { get }
    var architecture: String { get }

    var pifGUID: String { get }
}

public struct SWBPreviewInfo: SWBPreviewInfoContext, Equatable, Sendable {
    public let sdkRoot: String
    public let sdkVariant: String?
    public let buildVariant: String
    public let architecture: String

    public let pifGUID: String

    public let compileCommandLine: [String]
    public let linkCommandLine: [String] // empty when XOJIT is active

    public let thunkSourceFile: String
    public let thunkObjectFile: String
    public let thunkLibrary: String // empty when XOJIT is active

    @_spi(Testing) public init(sdkRoot: String, sdkVariant: String?, buildVariant: String, architecture: String, compileCommandLine: [String], linkCommandLine: [String], thunkSourceFile: String, thunkObjectFile: String, thunkLibrary: String, pifGUID: String) {
        self.sdkRoot = sdkRoot
        self.sdkVariant = sdkVariant
        self.buildVariant = buildVariant
        self.architecture = architecture
        self.compileCommandLine = compileCommandLine
        self.linkCommandLine = linkCommandLine
        self.thunkSourceFile = thunkSourceFile
        self.thunkObjectFile = thunkObjectFile
        self.thunkLibrary = thunkLibrary
        self.pifGUID = pifGUID
    }
}

public struct SWBPreviewTargetDependencyInfo: SWBPreviewInfoContext, Hashable, Sendable {
    public let sdkRoot: String
    public let sdkVariant: String?
    public let buildVariant: String
    public let architecture: String

    public let pifGUID: String

    /// Mapping of object files to the source file inputs they came from.
    public let objectFileInputMap: [String: Set<String>]

    /// Full command line for Previews to extract values as needed. This is the link command line of the preview stub dylib.
    public let linkCommandLine: [String]

    /// Working directory for the linker invocation.
    public let linkerWorkingDirectory: String?

    // The following build settings help Previews diagnose certain situations where it
    // won't succeed or offer help if something goes wrong.

    /// Reads from `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE`. This is required for Previews to
    /// dynamically substitute Swift UI view bodies.
    public let swiftEnableOpaqueTypeErasure: Bool

    /// Reads from  `SWIFT_USE_INTEGRATED_DRIVER`. This is required for Previews to to
    /// request the compiler invocation of any Swift file in order to build a
    /// replacement thunk.
    public let swiftUseIntegratedDriver: Bool

    /// Reads from `ENABLE_XOJIT_PREVIEWS`. This is overridden by the build system when
    /// conditions are determined to not be favorable to JIT previews (optimized builds,
    /// install action, etc). Previews needs to consult this as a last resort to know if
    /// it reached a stage where it thought it could preview in a target, but the build
    /// system determined that it definitely was not built for XOJIT Previews.
    public let enableJITPreviews: Bool

    /// Reads from `ENABLE_DEBUG_DYLIB`. This helps Previews determine that an
    /// executable target will not be previewable in JIT mode.
    public let enableDebugDylib: Bool

    /// Reads from `ENABLE_ADDRESS_SANITIZER`. Previews currently uses this to ask the
    /// user to disable the sanitizer in some cases where it is known to fail.
    public let enableAddressSanitizer: Bool

    /// Reads from `ENABLE_THREAD_SANITIZER`. Previews currently uses this to ask the
    /// user to disable the sanitizer in some cases where it is known to fail.
    public let enableThreadSanitizer: Bool

    /// Reads from `ENABLE_UNDEFINED_BEHAVIOR_SANITIZER`. Previews currently uses this to ask the
    /// user to disable the sanitizer in some cases where it is known to fail.
    public let enableUndefinedBehaviorSanitizer: Bool

    @_spi(Testing) public init(
        sdkRoot: String,
        sdkVariant: String? = nil,
        buildVariant: String,
        architecture: String,
        pifGUID: String,
        objectFileInputMap: [String : Set<String>],
        linkCommandLine: [String],
        linkerWorkingDirectory: String?,
        swiftEnableOpaqueTypeErasure: Bool,
        swiftUseIntegratedDriver: Bool,
        enableJITPreviews: Bool,
        enableDebugDylib: Bool,
        enableAddressSanitizer: Bool,
        enableThreadSanitizer: Bool,
        enableUndefinedBehaviorSanitizer: Bool
    ) {
        self.sdkRoot = sdkRoot
        self.sdkVariant = sdkVariant
        self.buildVariant = buildVariant
        self.architecture = architecture
        self.pifGUID = pifGUID
        self.objectFileInputMap = objectFileInputMap
        self.linkCommandLine = linkCommandLine
        self.linkerWorkingDirectory = linkerWorkingDirectory
        self.swiftEnableOpaqueTypeErasure = swiftEnableOpaqueTypeErasure
        self.swiftUseIntegratedDriver = swiftUseIntegratedDriver
        self.enableJITPreviews = enableJITPreviews
        self.enableDebugDylib = enableDebugDylib
        self.enableAddressSanitizer = enableAddressSanitizer
        self.enableThreadSanitizer = enableThreadSanitizer
        self.enableUndefinedBehaviorSanitizer = enableUndefinedBehaviorSanitizer
    }
}
