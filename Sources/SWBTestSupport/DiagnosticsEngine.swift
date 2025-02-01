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

package import Testing
package import SWBUtil
package import SWBCore

/// Helper to check the diagnostics in the engine.
package func DiagnosticsEngineTester(
    _ engine: DiagnosticsEngine,
    sourceLocation: SourceLocation = #_sourceLocation,
    result: (DiagnosticsEngineResult) throws -> Void
) {
    let engineResult = DiagnosticsEngineResult(engine)

    do {
        try result(engineResult)
    } catch {
        Issue.record("error \(String(describing: error))", sourceLocation: sourceLocation)
    }

    if !engineResult.uncheckedDiagnostics.isEmpty {
        let desc = engineResult.uncheckedDiagnostics.map(String.init(describing:)).joined(separator: "\n")
        Issue.record("unchecked diagnostics :\n\(desc)", sourceLocation: sourceLocation)
    }
}

final package class DiagnosticsEngineResult {

    fileprivate var uncheckedDiagnostics: [Diagnostic]

    init(_ engine: DiagnosticsEngine) {
        self.uncheckedDiagnostics = engine.diagnostics
    }

    package func check(
        diagnostic: StringCheck,
        checkContains: Bool = false,
        behavior: Diagnostic.Behavior,
        location: String? = nil,
        fixItStrings expectedFixItStrings: [String] = [],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard !uncheckedDiagnostics.isEmpty else {
            Issue.record("No diagnostics left to check", sourceLocation: sourceLocation)
            return
        }

        let location = location ?? Diagnostic.Location.unknown.localizedDescription
        let theDiagnostic = uncheckedDiagnostics.removeFirst()

        diagnostic.check(input: theDiagnostic.formatLocalizedDescription(.debugWithoutBehaviorAndLocation), sourceLocation: sourceLocation)
        #expect(theDiagnostic.behavior == behavior, sourceLocation: sourceLocation)
        #expect(theDiagnostic.location.localizedDescription == location, sourceLocation: sourceLocation)
        let actualFixItStrings = theDiagnostic.fixIts.map { $0.localizedDescription(includeLocation: true) }
        #expect(expectedFixItStrings.count == actualFixItStrings.count, sourceLocation: sourceLocation)
        for pair in zip(expectedFixItStrings, actualFixItStrings) {
            #expect(pair.1 == pair.0, sourceLocation: sourceLocation)
        }
    }
}

@available(*, unavailable)
extension DiagnosticsEngineResult: Sendable { }

package enum StringCheck: ExpressibleByStringLiteral, Sendable {
    case equal(String)
    case contains(String)

    func check(
        input: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch self {
        case .equal(let str):
            #expect(str == input, sourceLocation: sourceLocation)
        case .contains(let str):
            #expect(input.contains(str), "\(str) does not contain \(input)", sourceLocation: sourceLocation)
        }
    }

    package init(stringLiteral value: String) {
        self = .equal(value)
    }

    package init(extendedGraphemeClusterLiteral value: String) {
        self.init(stringLiteral: value)
    }

    package init(unicodeScalarLiteral value: String) {
        self.init(stringLiteral: value)
    }
}

extension Collection where Element == Diagnostic {
    package func pathMessageTuples(_ behavior: Diagnostic.Behavior) -> [(String, String)] {
        return compactMap {
            if $0.behavior == behavior {
                let description = $0.data.description
                switch $0.location {
                case let .path(path, _):
                    return (path.basename, description)
                case .buildFiles, .buildSettings, .unknown:
                    return ("<unknown>", description)
                }
            }
            return nil
        }.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 })
    }
}

extension Diagnostic {
    package func formatLocalizedDescription(_ format: LocalizedDescriptionFormat, targetAndWorkspace: (ConfiguredTarget, Workspace)?) -> String {
        if let (target, workspace) = targetAndWorkspace {
            return formatLocalizedDescription(format, target: target, workspace: workspace)
        } else {
            return formatLocalizedDescription(format)
        }
    }

    package func formatLocalizedDescription(_ format: LocalizedDescriptionFormat, target: ConfiguredTarget, workspace: Workspace) -> String {
        // Only emit the project path if the name is ambiguous
        let project = workspace.project(for: target.target)
        let isUnique = workspace.targets(named: target.target.name).count <= 1
        return "\(formatLocalizedDescription(format)) (in target '\(target.target.name)' from project '\(project.name)'\(!isUnique ? " at path '\(project.xcodeprojPath.str)'" : ""))"
    }

    package func formatLocalizedDescription(_ format: LocalizedDescriptionFormat, task: any ExecutableTask) -> String {
        "\(formatLocalizedDescription(format)) (for task: \(task.ruleInfo))"
    }
}

extension Dictionary where Key == Optional<ConfiguredTarget>, Value == [Diagnostic] {
    package func formatLocalizedDescription(_ format: Diagnostic.LocalizedDescriptionFormat, workspace: Workspace, filter: (Diagnostic) -> Bool) -> [String] {
        return map { ($0, $1.filter(filter)) }.flatMap { (target, diagnostics) -> [String] in
            diagnostics.map { $0.formatLocalizedDescription(format, targetAndWorkspace: target.map { ($0, workspace) } ?? nil) }
        }
    }
}
