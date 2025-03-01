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

public enum ToolchainCASPluginError: Error, Sendable, CustomStringConvertible {
    case missingRequiredSymbol(String)
    case settingCASOptionFailed(String?)
    case casCreationFailed(String?)
    case storeFailed(String?)
    case loadFailed(String?)
    case cacheInsertionFailed(String?)
    case cacheLookupFailed(String?)
    case casSizeOperationUnsupported
    case casSizeOperationFailed(String?)
    case casPruneOperationUnsupported
    case casPruneOperationFailed(String?)

    public var description: String {
        switch self {
        case .missingRequiredSymbol(let symbol):
            "missing required symbol: \(symbol)"
        case .settingCASOptionFailed(let detail):
            "setting CAS option failed: \(detail ?? "unknown error")"
        case .casCreationFailed(let detail):
            "creating CAS failed: \(detail ?? "unknown error")"
        case .storeFailed(let detail):
            "CAS store failed: \(detail ?? "unknown error")"
        case .loadFailed(let detail):
            "CAS load failed: \(detail ?? "unknown error")"
        case .cacheInsertionFailed(let detail):
            "cache insert failed: \(detail ?? "unknown error")"
        case .cacheLookupFailed(let detail):
            "cache lookup failed: \(detail ?? "unknown error")"
        case .casSizeOperationUnsupported:
            "CAS does not support size lookup"
        case .casSizeOperationFailed(let detail):
            "CAS size operation failed: \(detail ?? "unknown error")"
        case .casPruneOperationUnsupported:
            "CAS does not support pruning"
        case .casPruneOperationFailed(let detail):
            "CAS prune operation failed: \(detail ?? "unknown error")"
        }
    }
}
