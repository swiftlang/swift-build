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
import Foundation

enum HeaderKind: String {
    case publicHeader = "public"
    case privateHeader = "private"
}

@_spi(Testing)
public struct ModuleVerifierHeader : Hashable {
    @_spi(Testing) public var file: Path
    @_spi(Testing) public var unresolvedFile: Path
    @_spi(Testing) public var framework: String
    @_spi(Testing) public var subFolder: [String]
    @_spi(Testing) public var header: String

    @_spi(Testing) public func include(language: ModuleVerifierLanguage) -> String {
        var includeComponents: [String] = []
        includeComponents.append(framework)
        includeComponents.append(contentsOf: subFolder)
        includeComponents.append(header)
        return "\(language.includeStatement) <\(includeComponents.joined(separator: "/"))>"
    }

    @_spi(Testing) public init(header: Path, frameworkName: String) {
        self.file = header

        if header.str.contains("/Versions/A/") {
            self.unresolvedFile = Path(header.str.replacingOccurrences(of: "/Versions/A/", with: "/"))
        } else {
            self.unresolvedFile = header
        }
        self.framework = frameworkName
        self.header = header.basename

        // Find the intermediate directories from [Private]Headers to this header.
        var tail = header.dirname
        var subFolder: [String] = []
        while true {
            let component = tail.basename
            if component.isEmpty || component == "Headers"  || component == "PrivateHeaders" {
                break
            }
            tail = tail.dirname
            subFolder.append(component)
        }
        self.subFolder = subFolder.reversed()
    }
}

extension ModuleVerifierHeader : Comparable {
    @_spi(Testing)
    public static func < (lhs: ModuleVerifierHeader, rhs: ModuleVerifierHeader) -> Bool {
        lhs.include(language: .c) < rhs.include(language: .c)
    }
}
