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

import Testing
import SWBMacro

@Suite fileprivate struct MacroConditionBindingTests {
    @Test
    func bindingStringConditionValues() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        let sdk = namespace.declareConditionParameter("sdk")
        let arch = namespace.declareConditionParameter("arch")
        func conditions(_ conditions: (MacroConditionParameter, String)...) -> MacroConditionSet {
            MacroConditionSet(conditions: conditions.map { MacroCondition(parameter: $0.0, valuePattern: $0.1) })
        }

        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        let Z = try namespace.declareStringMacro("Z")
        let W = try namespace.declareStringMacro("W")
        let U = try namespace.declareStringMacro("U")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(X, literal: "base")
        table.push(X, literal: "mac", conditions: conditions((sdk, "macosx*")))
        table.push(X, literal: "ios", conditions: conditions((sdk, "iphoneos*")))
        table.push(Y, literal: "y")
        table.push(Y, literal: "fallback", conditions: conditions((sdk, "macosx")))
        table.push(Z, literal: "watch", conditions: conditions((sdk, "watchos*")))
        table.push(W, literal: "mac-arm", conditions: conditions((sdk, "macosx*"), (arch, "arm64")))
        table.push(U, literal: "u", conditions: conditions((arch, "x86_64")))

        let mac = table.bindConditionParameter(sdk, ["macosx27.0", "macosx"])
        let macScope = MacroEvaluationScope(table: mac)
        #expect(macScope.evaluate(X) == "mac")
        #expect(mac.lookupMacro(X)?.next?.expression.stringRep == "base")
        #expect(mac.lookupMacro(X)?.next?.next == nil)
        #expect(macScope.evaluate(Y) == "fallback")
        #expect(mac.lookupMacro(Z)?.conditions == conditions((sdk, "watchos*")))
        #expect(mac.lookupMacro(W)?.conditions == conditions((arch, "arm64")))
        #expect(mac.lookupMacro(U)?.conditions == conditions((arch, "x86_64")))

        let ios = table.bindConditionParameter(sdk, ["iphoneos27.0"])
        #expect(MacroEvaluationScope(table: ios).evaluate(X) == "ios")
        #expect(MacroEvaluationScope(table: ios).evaluate(Y) == "y")
        #expect(ios.lookupMacro(W)?.conditions == conditions((sdk, "macosx*"), (arch, "arm64")))

        let none = table.bindConditionParameter(sdk, ["driverkit"])
        #expect(MacroEvaluationScope(table: none).evaluate(X) == "base")
        #expect(none.lookupMacro(X)?.conditions == conditions((sdk, "iphoneos*")))
    }

    struct PrefixCondition: MacroValueAssignmentTable.CustomConditionParameterCondition {
        let prefix: String
        func matches(_ condition: MacroCondition) -> Bool { condition.valuePattern.hasPrefix(prefix) }
    }

    @Test
    func bindingCustomCondition() throws {
        let namespace = MacroNamespace(debugDescription: "test")
        let platform = namespace.declareConditionParameter("__platform_filter")
        let X = try namespace.declareStringMacro("X")
        let Y = try namespace.declareStringMacro("Y")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(X, literal: "base")
        table.push(X, literal: "ios", conditions: MacroConditionSet(conditions: [MacroCondition(parameter: platform, valuePattern: "ios")]))
        table.push(X, literal: "macos", conditions: MacroConditionSet(conditions: [MacroCondition(parameter: platform, valuePattern: "macos")]))
        table.push(Y, literal: "watchos", conditions: MacroConditionSet(conditions: [MacroCondition(parameter: platform, valuePattern: "watchos")]))

        let bound = table.bindConditionParameter(platform, PrefixCondition(prefix: "mac"))
        #expect(MacroEvaluationScope(table: bound).evaluate(X) == "macos")
        #expect(bound.lookupMacro(X)?.next?.expression.stringRep == "base")
        #expect(bound.lookupMacro(X)?.next?.next == nil)
        #expect(bound.lookupMacro(Y)?.conditions == MacroConditionSet(conditions: [MacroCondition(parameter: platform, valuePattern: "watchos")]))
    }
}
