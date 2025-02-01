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

import SWBProtocol
import SWBUtil

public import Foundation

public struct SWBBuildOperationBacktraceFrame: Hashable, Sendable, Codable, Identifiable {
    public struct Identifier: Equatable, Hashable, Sendable, Codable, CustomDebugStringConvertible {
        private enum Storage: Equatable, Hashable, Sendable, Codable {
            case task(BuildOperationTaskSignature)
            case key(String)
        }
        private let storage: Storage

        init(messageIdentifier: BuildOperationBacktraceFrameEmitted.Identifier) {
            switch messageIdentifier {
            case .task(let signature):
                self.storage = .task(signature)
            case .genericBuildKey(let id):
                self.storage = .key(id)
            }
        }

        public init?(taskSignatureData: Data) {
            guard let taskSignature = BuildOperationTaskSignature(rawValue: ByteString(taskSignatureData)) else {
                return nil
            }
            self.storage = .task(taskSignature)
        }

        public var debugDescription: String {
            switch storage {
            case .task(let taskSignature):
                return taskSignature.debugDescription
            case .key(let key):
                return key
            }
        }
    }

    public enum Category: Equatable, Hashable, Sendable, Codable {
        case ruleNeverBuilt
        case ruleSignatureChanged
        case ruleHadInvalidValue
        case ruleInputRebuilt
        case ruleForced
        case dynamicTaskRegistration
        case dynamicTaskRequest
        case none

        public var isUserFacing: Bool {
            switch self {
            case .ruleNeverBuilt, .ruleSignatureChanged, .ruleHadInvalidValue, .ruleInputRebuilt, .ruleForced, .dynamicTaskRequest, .none:
                return true
            case .dynamicTaskRegistration:
                return false
            }
        }
    }
    public enum Kind: Equatable, Hashable, Sendable, Codable {
        case genericTask
        case swiftDriverJob
        case file
        case directory
        case unknown
    }

    public let identifier: Identifier
    public let previousFrameIdentifier: Identifier?
    public let category: Category
    public let description: String
    public let frameKind: Kind

    // The old name collides with the `kind` key used in the SwiftBuildMessage JSON encoding
    @available(*, deprecated, renamed: "frameKind")
    public var kind: Kind {
        frameKind
    }

    public var id: Identifier {
        identifier
    }
}

extension SWBBuildOperationBacktraceFrame {
    init(_ message: BuildOperationBacktraceFrameEmitted) {
        let id = SWBBuildOperationBacktraceFrame.Identifier(messageIdentifier: message.identifier)
        let previousID = message.previousFrameIdentifier.map { SWBBuildOperationBacktraceFrame.Identifier(messageIdentifier: $0) }
        let category: SWBBuildOperationBacktraceFrame.Category
        switch message.category {
        case .ruleNeverBuilt:
            category = .ruleNeverBuilt
        case .ruleSignatureChanged:
            category = .ruleSignatureChanged
        case .ruleHadInvalidValue:
            category = .ruleHadInvalidValue
        case .ruleInputRebuilt:
            category = .ruleInputRebuilt
        case .ruleForced:
            category = .ruleForced
        case .dynamicTaskRegistration:
            category = .dynamicTaskRegistration
        case .dynamicTaskRequest:
            category = .dynamicTaskRequest
        case .none:
            category = .none
        }
        let kind: SWBBuildOperationBacktraceFrame.Kind
        switch message.kind {
        case .genericTask:
            kind = .genericTask
        case .swiftDriverJob:
            kind = .swiftDriverJob
        case .directory:
            kind = .directory
        case .file:
            kind = .file
        case .unknown:
            kind = .unknown
        case nil:
            kind = .unknown
        }
        self.init(identifier: id, previousFrameIdentifier: previousID, category: category, description: message.description, frameKind: kind)
    }
}
