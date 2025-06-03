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

public import struct Foundation.URL

extension URL {
    /// Returns the path of the file URL.
    ///
    /// This should always be used whenever the file path equivalent of a URL is needed. DO NOT use ``path`` or ``path(percentEncoded:)``, as these deal in terms of the path portion of the URL representation per RFC8089, which on Windows would include a leading slash.
    ///
    /// - throws: ``FileURLError`` if the URL does not represent a file or its path is otherwise not representable.
    public var filePath: Path {
        get throws {
            guard isFileURL else {
                throw FileURLError.notRepresentable(self)
            }
            return try withUnsafeFileSystemRepresentation { cString in
                guard let cString else {
                    throw FileURLError.notRepresentable(self)
                }
                let fp = Path(String(cString: cString))
                precondition(fp.isAbsolute, "path '\(fp.str)' is not absolute")
                return fp
            }
        }
    }
}

fileprivate enum FileURLError: Error, CustomStringConvertible {
    case notRepresentable(URL)

    var description: String {
        switch self {
        case .notRepresentable(let url):
            return "URL \(url) cannot be represented as an absolute file path"
        }
    }
}
