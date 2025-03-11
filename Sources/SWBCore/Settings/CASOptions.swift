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

import protocol Foundation.LocalizedError
public import SWBUtil
public import SWBMacro

public struct CASOptions: Hashable, Serializable, Encodable, Sendable {

    enum Errors: Error, CustomStringConvertible {
        case invalidSizeLimit(sizeLimitString: String, origin: String)
        case invalidPercentLimit(percentLimitString: String)

        var description: String {
            switch self {
            case .invalidSizeLimit(sizeLimitString: let sizeLimitString, origin: let origin):
                return "invalid \(origin): '\(sizeLimitString)'"
            case .invalidPercentLimit(percentLimitString: let percentLimitString):
                return "invalid COMPILATION_CACHE_LIMIT_PERCENT: '\(percentLimitString)'"
            }
        }
    }

    public enum SizeLimitingStrategy: Hashable, Serializable, Encodable, Sendable {
        /// Cache directory is removed after the build is finished.
        case discarded
        /// The maximum size for the cache directory in bytes. `nil` means no limit.
        case maxSizeBytes(Int?)
        /// The maximum size for the cache directory, in terms of percentage of the
        /// available space on the disk. Set to 100 to indicate no limit, 50 to
        /// indicate that the cache size will not be left over half the available disk
        /// space. A value over 100 will be reduced to 100.
        case maxPercentageOfAvailableSpace(Int)

        static var `default`: SizeLimitingStrategy {
            return .maxPercentageOfAvailableSpace(50)
        }

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(2) {
                switch self {
                case .discarded:
                    serializer.serialize(0)
                    serializer.serializeNil()
                case .maxSizeBytes(let size):
                    serializer.serialize(1)
                    serializer.serialize(size)
                case .maxPercentageOfAvailableSpace(let percent):
                    serializer.serialize(2)
                    serializer.serialize(percent)
                }
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            let type: Int = try deserializer.deserialize()
            switch type {
            case 0:
                self = .discarded
                _ = deserializer.deserializeNil()
            case 1:
                self = .maxSizeBytes(try deserializer.deserialize())
            case 2:
                self = .maxPercentageOfAvailableSpace(try deserializer.deserialize())
            default:
                throw DeserializerError.incorrectType("Unsupported type \(type)")
            }
        }
    }

    /// Parse a size limit string in this format:
    /// * Number ending in "M": size in megabytes
    /// * Number ending in "G": size in gigabytes
    /// * Number ending in "T": size in terabytes
    /// * Just integer: size in bytes
    /// * "0": indicates no limit
    ///
    /// Returns `nil` if the string is invalid.
    public static func parseSizeLimit(_ sizeLimitStr: String) -> Int? {
        if let size = Int(sizeLimitStr) {
            return size
        }
        guard let size = Int(sizeLimitStr.dropLast()) else {
            return nil
        }
        let kb = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let tb = gb * 1024
        switch sizeLimitStr.last! {
        case "K": // kilobytes
            return size * kb
        case "M": // megabytes
            return size * mb
        case "G": // gigabytes
            return size * gb
        case "T": // terabytes
            return size * tb
        default:
            return nil
        }
    }

    public var casPath: Path
    public var pluginPath: Path?
    public var remoteServicePath: Path?
    public var enableIntegratedCacheQueries: Bool
    public var enableDiagnosticRemarks: Bool
    public var enableStrictCASErrors: Bool
    /// If true, key queries avoid blocking or being restricted by the execution lanes.
    public var enableDetachedKeyQueries: Bool
    public var limitingStrategy: SizeLimitingStrategy

    public var hasRemoteCache: Bool {
        return remoteServicePath != nil
    }

    public init(
        casPath: Path,
        pluginPath: Path?,
        remoteServicePath: Path?,
        enableIntegratedCacheQueries: Bool,
        enableDiagnosticRemarks: Bool,
        enableStrictCASErrors: Bool,
        enableDetachedKeyQueries: Bool,
        limitingStrategy: SizeLimitingStrategy
    ) {
        self.casPath = casPath
        self.pluginPath = pluginPath
        self.remoteServicePath = remoteServicePath
        self.enableIntegratedCacheQueries = enableIntegratedCacheQueries
        self.enableDiagnosticRemarks = enableDiagnosticRemarks
        self.enableStrictCASErrors = enableStrictCASErrors
        self.enableDetachedKeyQueries = enableDetachedKeyQueries
        self.limitingStrategy = limitingStrategy
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(8) {
            serializer.serialize(casPath)
            serializer.serialize(pluginPath)
            serializer.serialize(remoteServicePath)
            serializer.serialize(enableIntegratedCacheQueries)
            serializer.serialize(enableDiagnosticRemarks)
            serializer.serialize(enableStrictCASErrors)
            serializer.serialize(enableDetachedKeyQueries)
            serializer.serialize(limitingStrategy)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(8)
        self.casPath = try deserializer.deserialize()
        self.pluginPath = try deserializer.deserialize()
        self.remoteServicePath = try deserializer.deserialize()
        self.enableIntegratedCacheQueries = try deserializer.deserialize()
        self.enableDiagnosticRemarks = try deserializer.deserialize()
        self.enableStrictCASErrors = try deserializer.deserialize()
        self.enableDetachedKeyQueries = try deserializer.deserialize()
        self.limitingStrategy = try deserializer.deserialize()
    }

    public enum Purpose: Sendable {
        case generic
        case compiler(GCCCompatibleLanguageDialect)
    }

    public static func create(
        _ scope: MacroEvaluationScope,
        _ purpose: Purpose
    ) throws -> CASOptions {
        func isLanguageSupportedForRemoteCaching() -> Bool {
            switch purpose {
            case .compiler(let language):
                let supportedLangs = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES)
                // If no specific list of languages is provided then all languages are supported.
                guard !supportedLangs.isEmpty else { return true }
                // If we're  not compiling a specific language, assume support.
                return supportedLangs.contains(language.dialectNameForCompilerCommandLineArgument)
            case .generic:
                return true
            }
        }

        let casPath: Path
        let pluginPath: Path?
        let remoteServicePath: Path?
        let enableIntegratedCacheQueries = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES)
        let enableDiagnosticRemarks = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS)
        let enableStrictCASErrors = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_ENABLE_STRICT_CAS_ERRORS)
        let enableDetachedKeyQueries = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_ENABLE_DETACHED_KEY_QUERIES)
        if scope.evaluate(BuiltinMacros.COMPILATION_CACHE_ENABLE_PLUGIN) {
            casPath = Path(scope.evaluate(BuiltinMacros.COMPILATION_CACHE_CAS_PATH)).join("plugin")
            pluginPath = Path(scope.evaluate(BuiltinMacros.COMPILATION_CACHE_PLUGIN_PATH))
            let remoteServicePathSetting = Path(scope.evaluate(BuiltinMacros.COMPILATION_CACHE_REMOTE_SERVICE_PATH))
            if !remoteServicePathSetting.isEmpty && isLanguageSupportedForRemoteCaching() {
                remoteServicePath = remoteServicePathSetting
            } else {
                remoteServicePath = nil
            }
        } else {
            switch purpose {
            case .compiler:
                casPath = Path(scope.evaluate(BuiltinMacros.COMPILATION_CACHE_CAS_PATH)).join("builtin")
            case .generic:
                casPath = Path(scope.evaluate(BuiltinMacros.COMPILATION_CACHE_CAS_PATH)).join("generic")
            }
            pluginPath = nil
            remoteServicePath = nil
        }

        let limitingStrategy: CASOptions.SizeLimitingStrategy = try {
            guard scope.evaluate(BuiltinMacros.COMPILATION_CACHE_KEEP_CAS_DIRECTORY) else {
                return .discarded
            }

            func parseSizeLimit(_ sizeLimitStr: String, origin: String) throws -> CASOptions.SizeLimitingStrategy {
                guard let sizeLimit = CASOptions.parseSizeLimit(sizeLimitStr) else {
                    throw Errors.invalidSizeLimit(sizeLimitString: sizeLimitStr, origin: origin)
                }
                return .maxSizeBytes(sizeLimit > 0 ? sizeLimit : nil)
            }

            let sizeLimitStr = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_LIMIT_SIZE)
            if !sizeLimitStr.isEmpty {
                return try parseSizeLimit(sizeLimitStr, origin: "COMPILATION_CACHE_LIMIT_SIZE")
            }

            let percentLimitStr = scope.evaluate(BuiltinMacros.COMPILATION_CACHE_LIMIT_PERCENT)
            if !percentLimitStr.isEmpty {
                guard let percent = Int(percentLimitStr) else {
                    throw Errors.invalidPercentLimit(percentLimitString: percentLimitStr)
                }
                return .maxPercentageOfAvailableSpace(percent)
            }

            if let sizeLimitDefault = UserDefaults.compilationCachingDiskSizeLimit {
                return try parseSizeLimit(sizeLimitDefault, origin: "CompilationCachingDiskSizeLimit default")
            }

            return .default
        }()

        return CASOptions(
            casPath: casPath,
            pluginPath: pluginPath,
            remoteServicePath: remoteServicePath,
            enableIntegratedCacheQueries: enableIntegratedCacheQueries,
            enableDiagnosticRemarks: enableDiagnosticRemarks,
            enableStrictCASErrors: enableStrictCASErrors,
            enableDetachedKeyQueries: enableDetachedKeyQueries,
            limitingStrategy: limitingStrategy
        )
    }
}
