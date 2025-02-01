//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

public struct TBDFile: Sendable {
    public let platforms: Set<TBDPlatform>

    public init(_ path: Path) throws {
        // TODO: This should use a real YAML parser, but we don't have one accessible from here.
        // This should serve our limited purposes well enough for now.
        let reader = try LineReader(forReadingFrom: URL(fileURLWithPath: path.str))
        switch try reader.readLine() {
        case "--- !tapi-tbd-v3":
            while let line = try reader.readLine() {
                if line.hasPrefix("platform:") {
                    let pieces = line.split(separator: " ")
                    if pieces.count == 2 {
                        platforms = try TBDPlatform.fromV3(string: String(pieces[1]))
                        return
                    }
                    break
                }
            }

            throw StubError.error("Could not determine platform of version 3 TBD file")
        case "--- !tapi-tbd" where try reader.readLine()?.split(separator: " ") == ["tbd-version:", "4"]:
            while let line = try reader.readLine() {
                if line.hasPrefix("targets:") {
                    let pieces = line.split(whereSeparator: { [" ", ","].contains($0) }).filter { !["targets:", "[", "]", ","].contains($0) }
                    if !pieces.isEmpty {
                        platforms = try Set(pieces.map { piece in
                            try TBDPlatform.fromV4(string: String(piece.split("-").1))
                        })
                        return
                    }
                    break
                }
            }

            throw StubError.error("Could not determine platform of version 4 TBD file")
        default:
            break
        }

        throw StubError.error("Could not parse TBD file")
    }
}

public enum TBDPlatform: Sendable {
    case unknown

    case macOS
    case iOS
    case tvOS
    case watchOS

    case macCatalyst

    case driverKit
}

fileprivate extension TBDPlatform {
    static func fromV3(string: String) throws -> Set<Self> {
        switch string {
        case "unknown":
            return [.unknown]
        case "zippered":
            return [.macOS, .macCatalyst]
        case "macosx":
            return [.macOS]
        case "ios":
            return [.iOS]
        case "tvos":
            return [.tvOS]
        case "watchos":
            return [.watchOS]
        case "maccatalyst":
            return [.macCatalyst]
        case "driverkit":
            return [.driverKit]
        default:
            throw StubError.error("Could not parse TBD platform string '\(string)'")
        }
    }

    static func fromV4(string: String) throws -> Self {
        switch string {
        case "unknown":
            return .unknown
        case "macos":
            return .macOS
        case "ios", "ios-simulator":
            return .iOS
        case "tvos", "tvos-simulator":
            return .tvOS
        case "watchos", "watchos-simulator":
            return .watchOS
        case "maccatalyst":
            return .macCatalyst
        case "driverkit":
            return .driverKit
        default:
            throw StubError.error("Could not parse TBD platform string '\(string)'")
        }
    }
}
