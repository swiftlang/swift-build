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

public import SWBCore
public import SWBUtil

public final class AssetCatalogCompilerOutputParser : GenericOutputParser {
    /// Regex to extract location information from a diagnostic prefix (capture group 0 is the name, 1 is the line number or the object identifier).
    static let locRegex = RegEx(patternLiteral: "^([^:]+):(?:([^:]+):)? +$")

    /// Private function that parses and returns a DiagnosticLocation based on a fragment of the input string.
    public override func parseLocation(_ string: String, in workingDirectory: Path) -> Diagnostic.Location? {
        if let match = AssetCatalogCompilerOutputParser.locRegex.matchGroups(in: string).first {
            let filename = match[0]
            // If the match is one of the tool basename, it is not a filename.
            if !toolBasenames.contains(filename) {
                // Otherwise, we assume it's in traditional "path:identifier" form, where identifier is optional and represents a line number or a custom object identifier.
                let fileLocation: Diagnostic.FileLocation
                if let lineNumber = Int(match[1]) {
                    fileLocation = .textual(line: lineNumber, column: nil)
                } else {
                    fileLocation = .object(identifier: match[1])
                }
                return .path((Path(filename).makeAbsolute(relativeTo: workingDirectory) ?? Path(filename)).normalize(), fileLocation: fileLocation)
            }
        }
        return nil
    }
}
