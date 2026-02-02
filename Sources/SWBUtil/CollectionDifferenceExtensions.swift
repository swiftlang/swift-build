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

extension CollectionDifference<String> {
    package var humanReadableDescription: String {
        var changeDescriptions: [String] = []
        var reportedMoves: Set<Int> = []
        for change in self.inferringMoves() {
            if reportedMoves.contains(change.offset) {
                continue
            }
            switch change {
            case .insert(offset: let offset, element: let element, associatedWith: let associatedWith):
                if let associatedWith {
                    reportedMoves.insert(associatedWith)
                    changeDescriptions.append("moved '\(element)'")
                } else {
                    changeDescriptions.append("inserted '\(element)'")
                }
            case .remove(offset: let offset, element: let element, associatedWith: let associatedWith):
                if let associatedWith {
                    reportedMoves.insert(associatedWith)
                    changeDescriptions.append("moved '\(element)'")
                } else {
                    changeDescriptions.append("removed '\(element)'")
                }
            }
        }
        return changeDescriptions.joined(separator: ", ")
    }
}

extension CollectionDifference<Character> {
    package var humanReadableDescription: String {
        var processedChanges: [(verb: String, lastOffset: Int, string: String)] = []

        for change in self.inferringMoves() {
            switch change {
            case .insert(offset: let offset, element: let element, associatedWith: let associatedWith):
                if let lastIndex = processedChanges.indices.last, processedChanges[lastIndex].verb == "inserted", processedChanges[lastIndex].lastOffset == offset - 1 {
                    processedChanges[lastIndex].string.append(element)
                    processedChanges[lastIndex].lastOffset = offset
                } else {
                    processedChanges.append((verb: "inserted", lastOffset: offset, string: String(element)))
                }
            case .remove(offset: let offset, element: let element, associatedWith: _):
                if let lastIndex = processedChanges.indices.last, processedChanges[lastIndex].verb == "removed", processedChanges[lastIndex].lastOffset == offset + 1 {
                    processedChanges[lastIndex].string.insert(element, at: processedChanges[lastIndex].string.startIndex)
                    processedChanges[lastIndex].lastOffset = offset
                } else {
                    processedChanges.append((verb: "removed", lastOffset: offset, string: String(element)))
                }
            }
        }

        let changeDescriptions = processedChanges.map { change in
            "\(change.verb) '\(change.string)'"
        }

        return changeDescriptions.joined(separator: ", ")
    }
}

extension CollectionDifference<(String, String)> {
    public var humanReadableEnvironmentDiff: String {
        var changeDescriptions: [String] = []
        for change in self {
            switch change {
            case .insert(offset: _, element: let element, associatedWith: _):
                changeDescriptions.append("inserted '\(element.0)=\(element.1)'")
            case .remove(offset: _, element: let element, associatedWith: _):
                changeDescriptions.append("removed '\(element.0)=\(element.1)'")
            }
        }
        return changeDescriptions.joined(separator: ", ")
    }
}
