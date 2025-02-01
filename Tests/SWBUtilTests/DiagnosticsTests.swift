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

import Foundation
import Testing
import SWBUtil

@Suite fileprivate struct DiagnosticsTests {
    @Test
    func serialization() throws {
        let data = DiagnosticData("best error", component: .packageResolution)
        let diagnostic = Diagnostic(behavior: .note, location: .path(Path("/usr/local"), line: 23, column: 78), data: data, appendToOutputStream: false)

        let sz = MsgPackSerializer()
        sz.serialize(diagnostic)

        let dsz = MsgPackDeserializer(sz.byteString)
        let dszDiagnostic: Diagnostic = try dsz.deserialize()

        #expect(diagnostic.appendToOutputStream == dszDiagnostic.appendToOutputStream)
        #expect(diagnostic.behavior == dszDiagnostic.behavior)
        #expect(diagnostic.data.component == dszDiagnostic.data.component)
        #expect(diagnostic.data.description == dszDiagnostic.data.description)
        #expect(diagnostic.location == dszDiagnostic.location)
    }

    @Test
    func serializationWithUnknownDiagnosticLocation() throws {
        let data = DiagnosticData("best error", component: .packageResolution)
        let diagnostic = Diagnostic(behavior: .note, location: .unknown, data: data, appendToOutputStream: false)

        let sz = MsgPackSerializer()
        sz.serialize(diagnostic)

        let dsz = MsgPackDeserializer(sz.byteString)
        let dszDiagnostic: Diagnostic = try dsz.deserialize()

        #expect(diagnostic.location.localizedDescription == dszDiagnostic.location.localizedDescription)
    }
}
