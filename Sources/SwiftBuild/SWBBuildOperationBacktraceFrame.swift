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

public struct SWBBuildOperationBacktraceFrame: Hashable, Sendable, Codable, Identifiable, Comparable {
    public struct Identifier: Equatable, Comparable, Hashable, Sendable, Codable, CustomDebugStringConvertible {
        private enum Storage: Equatable, Comparable, Hashable, Sendable, Codable {
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

        package init(genericBuildKey: String) {
            self.storage = .key(genericBuildKey)
        }

        public var debugDescription: String {
            switch storage {
            case .task(let taskSignature):
                return taskSignature.debugDescription
            case .key(let key):
                return key
            }
        }

        public static func < (lhs: SWBBuildOperationBacktraceFrame.Identifier, rhs: SWBBuildOperationBacktraceFrame.Identifier) -> Bool {
            lhs.storage < rhs.storage
        }
    }

    public enum Category: Equatable, Comparable, Hashable, Sendable, Codable {
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
    public enum Kind: Equatable, Comparable, Hashable, Sendable, Codable {
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

    package init(identifier: Identifier, previousFrameIdentifier: Identifier?, category: Category, description: String, frameKind: Kind) {
        self.identifier = identifier
        self.previousFrameIdentifier = previousFrameIdentifier
        self.category = category
        self.description = description
        self.frameKind = frameKind
    }

    // The old name collides with the `kind` key used in the SwiftBuildMessage JSON encoding
    @available(*, deprecated, renamed: "frameKind")
    public var kind: Kind {
        frameKind
    }

    public var id: Identifier {
        identifier
    }

    public static func < (lhs: SWBBuildOperationBacktraceFrame, rhs: SWBBuildOperationBacktraceFrame) -> Bool {
        (lhs.identifier, lhs.previousFrameIdentifier, lhs.category, lhs.description, lhs.frameKind) < (rhs.identifier, rhs.previousFrameIdentifier, rhs.category, rhs.description, rhs.frameKind)
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

public struct SWBBuildOperationCollectedBacktraceFrames {
    fileprivate var frames: [SWBBuildOperationBacktraceFrame.Identifier: Set<SWBBuildOperationBacktraceFrame>]

    public init() {
        self.frames = [:]
    }

    public mutating func add(frame: SWBBuildOperationBacktraceFrame) {
        frames[frame.identifier, default: []].insert(frame)
    }
}

public struct SWBTaskBacktrace {
    public let frames: [SWBBuildOperationBacktraceFrame]

    public init?(from baseFrameID: SWBBuildOperationBacktraceFrame.Identifier, collectedFrames: SWBBuildOperationCollectedBacktraceFrames) {
        var frames: [SWBBuildOperationBacktraceFrame] = []
        var currentFrame = collectedFrames.frames[baseFrameID]?.only
        while let frame = currentFrame {
            frames.append(frame)
            if let previousFrameID = frame.previousFrameIdentifier, let candidatesForNextFrame = collectedFrames.frames[previousFrameID] {
                switch frame.category {
                case .dynamicTaskRegistration:
                    currentFrame = candidatesForNextFrame.sorted().first {
                        $0.category == .dynamicTaskRequest
                    }
                default:
                    currentFrame = candidatesForNextFrame.sorted().first
                }
            } else {
                currentFrame = nil
            }
        }
        guard !frames.isEmpty else {
            return nil
        }
        self.frames = frames
    }

    public func renderTextualRepresentation() -> String {
        var textualBacktrace: String = ""
        for (frameNumber, frame) in frames.enumerated() {
            guard frame.category.isUserFacing else {
                continue
            }
            textualBacktrace += "#\(frameNumber): \(frame.description)\n"
        }
        return textualBacktrace
    }
}
