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

package import SWBUtil
package import Testing

package protocol DiagnosticsCheckingResult: AnyObject {
    associatedtype DiagnosticType
    typealias DiagnosticKind = Diagnostic.Behavior

    var checkedErrors: Bool { get set }
    var checkedWarnings: Bool { get set }
    var checkedNotes: Bool { get set }
    var checkedRemarks: Bool { get set }

    /// Return all diagnostics in the received which match `forKind`.
    func getDiagnostics(_ forKind: DiagnosticKind) -> [String]

    /// Check for a single diagnostic of type `kind` matching `pattern` in the receiver. If there is a match, consume and return its message, otherwise return nil.
    func getDiagnosticMessage(_ pattern: StringPattern, kind: DiagnosticKind, checkDiagnostic: (DiagnosticType) -> Bool) -> String?

    /// Check for a single diagnostic of type `kind` matching `pattern` in the receiver. Consume it if there is a match, and emit a test failure if not.
    func check(_ pattern: StringPattern, kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation, checkDiagnostic: (DiagnosticType) -> Bool) -> Bool

    /// Check for diagnostics of type `kind` in `diagnostics` which match `patterns`. Emit a test failure if any pattern cannot be found, and also if not all diagnostics are consumed by the patterns.
    func check(_ patterns: [StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation) -> Bool
}

extension DiagnosticsCheckingResult {
    private func getFilteredDiagnostics(_ forKind: DiagnosticKind) -> [String] {
        return getDiagnostics(forKind).compactMap {
            filterDiagnostic(message: $0)
        }
    }

    /// Get the list of all errors.
    /// - remark: If the test calls this method then it must perform all checking of errors itself, as calling this method will disable automatic checking in the tester.
    package func getErrors() -> [String] {
        checkedErrors = true
        return getFilteredDiagnostics(.error)
    }

    /// Get the list of all warnings.
    /// - remark: If the test calls this method then it must perform all checking of warnings itself, as calling this method will disable automatic checking in the tester.
    package func getWarnings() -> [String] {
        checkedWarnings = true
        return getFilteredDiagnostics(.warning)
    }

    /// Get the list of all notes.
    /// - remark: If the test calls this method then it must perform all checking of notes itself, as calling this method will disable automatic checking in the tester.
    package func getNotes() -> [String] {
        checkedNotes = true
        return getFilteredDiagnostics(.note)
    }

    /// Get the list of all remarks.
    /// - remark: If the test calls this method then it must perform all checking of remarks itself, as calling this method will disable automatic checking in the tester.
    package func getRemarks() -> [String] {
        checkedRemarks = true
        return getFilteredDiagnostics(.remark)
    }

    /// Find a particular error.
    @discardableResult package func checkError(_ pattern: StringPattern, failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation, checkDiagnostic: (DiagnosticType) -> Bool = { _ in true }) -> Bool {
        return check(pattern, kind: .error, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation, checkDiagnostic: checkDiagnostic)
    }

    /// Find a particular warning.
    @discardableResult package func checkWarning(_ pattern: StringPattern, failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation, checkDiagnostic: (DiagnosticType) -> Bool = { _ in true }) -> Bool {
        return check(pattern, kind: .warning, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation, checkDiagnostic: checkDiagnostic)
    }

    /// Find a particular note.
    @discardableResult package func checkNote(_ pattern: StringPattern, failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation, checkDiagnostic: (DiagnosticType) -> Bool = { _ in true }) -> Bool {
        return check(pattern, kind: .note, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation, checkDiagnostic: checkDiagnostic)
    }

    @discardableResult package func checkRemark(_ pattern: StringPattern, failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation, checkDiagnostic: (DiagnosticType) -> Bool = { _ in true }) -> Bool {
        return check(pattern, kind: .remark, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation, checkDiagnostic: checkDiagnostic)
    }

    @discardableResult package func checkErrors(_ patterns: [StringPattern], failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        return check(patterns, diagnostics: getErrors(), kind: .error, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation)
    }

    @discardableResult package func checkWarnings(_ patterns: [StringPattern], failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        return check(patterns, diagnostics: getWarnings(), kind: .warning, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation)
    }

    @discardableResult package func checkNotes(_ patterns: [StringPattern], failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        return check(patterns, diagnostics: getNotes(), kind: .note, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation)
    }

    @discardableResult package func checkRemarks(_ patterns: [StringPattern], failIfNotFound: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        return check(patterns, diagnostics: getRemarks(), kind: .remark, failIfNotFound: failIfNotFound, sourceLocation: sourceLocation)
    }

    package func checkNoErrors(sourceLocation: SourceLocation = #_sourceLocation) {
        for error in getErrors() {
            Issue.record("found unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    package func checkNoWarnings(sourceLocation: SourceLocation = #_sourceLocation) {
        for warning in getWarnings() {
            Issue.record("found unexpected warning: \(warning)", sourceLocation: sourceLocation)
        }
    }

    package func checkNoNotes(sourceLocation: SourceLocation = #_sourceLocation) {
        for note in getNotes() {
            Issue.record("found unexpected note: \(note)", sourceLocation: sourceLocation)
        }
    }

    package func checkNoRemarks(sourceLocation: SourceLocation = #_sourceLocation) {
        for remark in getRemarks() {
            Issue.record("found unexpected remark: \(remark)", sourceLocation: sourceLocation)
        }
    }

    /// Check that there were no errors, warnings, notes, or remarks.
    package func checkNoDiagnostics(sourceLocation: SourceLocation = #_sourceLocation) {
        checkNoErrors(sourceLocation: sourceLocation)
        checkNoWarnings(sourceLocation: sourceLocation)
        // rdar://143085331 (Enable `checkNoNotes()` in `checkNoDiagnostics`)
        // checkNoNotes(sourceLocation: sourceLocation)
        checkNoRemarks(sourceLocation: sourceLocation)
    }

    /// Check that there were no errors or warnings, if not otherwise checked.
    @discardableResult package func validate(sourceLocation: SourceLocation) -> (hadUncheckedErrors: Bool, hadUncheckedWarnings: Bool) {
        var hadUncheckedErrors = false
        var hadUncheckedWarnings = false
        if !checkedErrors {
            checkNoErrors(sourceLocation: sourceLocation)
            hadUncheckedErrors = !getErrors().isEmpty
        }
        if !checkedWarnings {
            checkNoWarnings(sourceLocation: sourceLocation)
            hadUncheckedWarnings = !getWarnings().isEmpty
        }
        return (hadUncheckedErrors: hadUncheckedErrors, hadUncheckedWarnings: hadUncheckedWarnings)
    }
}

extension DiagnosticsCheckingResult {
    package func checkNoStaleFileRemovalNotes(sourceLocation: SourceLocation = #_sourceLocation) {
        let filtered = getNotes().filter { $0.contains("Removed stale file") }
        if !filtered.isEmpty {
            Issue.record("Found stale file removals: \(filtered.joined(separator: "\n"))", sourceLocation: sourceLocation)
        }
    }
}

extension DiagnosticsCheckingResult {
    /// Filters out diagnostics from test harnesses reporting them, for temporary bug workarounds. Do not remove this method even if it is empty and only returns `message`, as its contents may fluctuate over time.
    package func filterDiagnostic(message: String) -> String? {
        _filterDiagnostic(message: message)
    }
}

package func _filterDiagnostic(message: String) -> String? {
    // Workaround:
    // rdar://91593134 ("did not find a prebuilt standard library for target" warning is very disruptive)
    // rdar://91560323 (⚠️ SWBLibc: did not find a prebuilt standard library for target 'x*_*-apple-macos' compatible with this Swift compiler; building it may take a few minutes, but it should only happen once for this combination of compiler and target)
    if message.hasPrefix("did not find a prebuilt standard library for target") {
        return nil
    }

    // Workaround: rdar://91560327
    if message.contains("add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'Foundation'") {
        return nil
    }

    // Workaround: rdar://118453609
    if message.contains(#/imported declaration '.+' could not be mapped to '.+'/#) {
        return nil
    }

    if message.contains("linkmetadataprocessor extraction skipped. No AppIntents.framework dependency found.") {
        return nil
    }

    // rdar://137565964 (REGRESSION: Linking any Swift program back-deployed emits warnings)
    if message.contains(#/[oO]bject file .+\/libswiftCompatibility.+ was built for newer '.+' version \(.+\) than being linked \(.+\)/#) {
        return nil
    }

    // Workaround: rdar://141686644
    if message.contains("In-process dependency scan query failed due to incompatible libSwiftScan") {
        return nil
    }

    if message.hasPrefix("Enabling the Swift language feature 'MemberImportVisibility' will become a requirement in the future") {
        return nil
    }

    if message.hasPrefix("Learn more about 'MemberImportVisibility' by visiting") {
        return nil
    }

    // Workaround: rdar://146492614
    if message.contains(#/Search path '.+\/System\/iOSSupport\/System\/Library\/SubFrameworks' not found/#) {
        return nil
    }

    return message
}
