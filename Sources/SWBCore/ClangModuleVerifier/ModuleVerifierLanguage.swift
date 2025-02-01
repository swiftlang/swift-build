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

/// Language supported by the Clang Module Verifier.
public enum ModuleVerifierLanguage: String, CaseIterable {
    case c = "c"
    case cPlusPlus = "c++"
    case objectiveC = "objective-c"
    case objectiveCPlusPlus = "objective-c++"

    public enum Standard: String, CaseIterable {
        case ansi = "ansi"
        case c89 = "c89"
        case gnu89 = "gnu89"
        case c99 = "c99"
        case gnu99 = "gnu99"
        case c11 = "c11"
        case gnu11 = "gnu11"
        case c17 = "c17"
        case gnu17 = "gnu17"
        case c23 = "c23"
        case gnu23 = "gnu23"

        fileprivate static var cStandards: Set<Self> {
            return [.ansi, .c89, .gnu89, .c99, .gnu99, .c11, .gnu11, .c17, .gnu17, .c23, .gnu23]
        }

        case cPlusPlus98 = "c++98"
        case gnuPlusPlus98 = "gnu++98"
        case cPlusPlus11 = "c++11"
        case gnuPlusPlus11 = "gnu++11"
        case cPlusPlus14 = "c++14"
        case gnuPlusPlus14 = "gnu++14"
        case cPlusPlus17 = "c++17"
        case gnuPlusPlus17 = "gnu++17"
        case cPlusPlus20 = "c++20"
        case gnuPlusPlus20 = "gnu++20"
        case cPlusPlus23 = "c++23"
        case gnuPlusPlus23 = "gnu++23"
        case cPlusPlus26 = "c++26"
        case gnuPlusPlus26 = "gnu++26"

        fileprivate static var cPlusPlusStandards: Set<Self> {
            return [.cPlusPlus98, .gnuPlusPlus98, .cPlusPlus11, .gnuPlusPlus11, .cPlusPlus14, .gnuPlusPlus14, .cPlusPlus17, .gnuPlusPlus17, .cPlusPlus20, .gnuPlusPlus20, .cPlusPlus23, .gnuPlusPlus23, .cPlusPlus26, .gnuPlusPlus26]
        }
    }

    public func standards(from standards: [Standard]) -> Set<Standard> {
        switch self {
        case .c, .objectiveC:
            return Standard.cStandards.intersection(standards)
        case .cPlusPlus, .objectiveCPlusPlus:
            return Standard.cPlusPlusStandards.intersection(standards)
        }
    }

    public var includeStatement: String {
        switch self {
        case .c, .cPlusPlus:
            return "#include"
        case .objectiveC, .objectiveCPlusPlus:
            return "#import"
        }
    }

    public var preferredSourceFilenameExtension: String {
        // The correct thing would be to get the UTType associated with self, and return
        // preferredFilenameExtension. However, LaunchServices isn't available in all environments.
        // Hard code the results from UTType.
        switch self {
        case .c:
            return "c"
        case .cPlusPlus:
            // rdar://98800763 (UTType.cPlusPlusSource.preferredFilenameExtension says "cp", but the more conventional extension is "cpp")
            return "cpp"
        case .objectiveC:
            return "m"
        case .objectiveCPlusPlus:
            return "mm"
        }
    }
}
