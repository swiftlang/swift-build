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
public import SWBCore

public final class StringCatalogCompilerOutputParser : GenericOutputParser {
    // In String Catalogs, the only unique identifier we really have for an "object" is the string key itself, and that could be a really long piece of text.
    // Thus, xcstringstool outputs its diagnostics like this:
    // /Users/mattseaman/Developer/RocketShip/RocketShip/Localizable.xcstrings: error: Referencing undefined substitution 'arg3' (en: Next meeting at %lld %lld)
    // Where "Next meeting at %lld %lld" is the string key.

    /// The parsed file location from the message.
    private var parsedLocation: Diagnostic.FileLocation?

    public override func parseMessage(_ string: String) -> String {
        // Regex for parsing the message portion, which contains language and key info at the end in parenthesis. Capture groups are message, language, and key.
        // Using reluctant quantifier on initial message just in case the key itself contains some similar-looking pattern.
        // The location is really part of the message.
        guard let match = try? #/^(?<message>.*?) \((?<language>[^:'" ]+): (?<key>.*)\)$/#.firstMatch(in: string) else {
            parsedLocation = nil
            return string
        }

        // "languageCode:key"
        let objectID = "\(match.language):\(match.key)"

        parsedLocation = .object(identifier: objectID)

        return String(match.message)
    }

    public override func parseLocation(_ string: String, in workingDirectory: Path) -> Diagnostic.Location? {
        /// Regex for parsing the "location" at the beginning, which is just the file path. Single capture group is the file path.
        guard let filename = try? #/^(?<filename>.+): $/#.firstMatch(in: string)?.filename else {
            return nil
        }

        return .path((Path(filename).makeAbsolute(relativeTo: workingDirectory) ?? Path(filename)).normalize(), fileLocation: parsedLocation)
    }
}
