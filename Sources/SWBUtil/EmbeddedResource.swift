//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package enum EmbeddedResourceObjectFormat: String, Hashable, Sendable {
    case elf
    case macho
}

package struct EmbeddedResourceObjectInfo: Sendable {
    package let variableName: String
    package let dataSymbol: String
    package let sectionName: String
    package let identifier: String

    package init(moduleName: String, path: Path, objectFormat: EmbeddedResourceObjectFormat) {
        let moduleName = moduleName.mangledToC99ExtendedIdentifier()
        let variableName = path.basename.mangledToC99ExtendedIdentifier()
        let hash = SHA256Context()
        hash.add(string: "\(moduleName):\(path.basename)")
        let identifier = String(hash.signature.asString.prefix(10)).lowercased()

        self.variableName = variableName
        self.dataSymbol = "swiftpm_resource_\(moduleName)_\(variableName)_data"
        self.sectionName = objectFormat == .macho ? "__spm\(identifier)" : "swiftpm_\(identifier)"
        self.identifier = identifier
    }
}
