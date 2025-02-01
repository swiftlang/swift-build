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

public struct ModuleVerifierFilenameMap {
    private var filenameMap: [String: String] = [:]

    public init() {
    }

    public init(from filenameMap: Path, fs: any FSProxy) {
        self.init(from: URL(fileURLWithPath: filenameMap.str, isDirectory: false), fs: fs)
    }

    init(from filenameMapURL: URL, fs: any FSProxy) {
        do {
            let filenameMapData = try JSONDecoder().decode(FilenameMapData.self, from: filenameMapURL.filePath, fs: fs)
            self.filenameMap = filenameMapData.contents
        } catch {
            self.filenameMap = [:]
        }
    }

    public func map(filename: String) -> String? {
        return self.filenameMap[filename]
    }
}

private struct FilenameMapData: Codable {
    let caseSensitive: String
    let contents: [String: String]
    let version: String

    enum CodingKeys: String, CodingKey {
        case caseSensitive = "case-sensitive"
        case contents, version
    }
}
