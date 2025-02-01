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
@_spi(Testing) import SWBCore
import SWBUtil
import Testing

@Suite fileprivate struct ModuleVerifierTargetTests {
    @Test
    func targets() throws {
        let targets = ["a-1", "b-1"]
        let targetVariants = ["a-2"]
        let combinations = ModuleVerifierTargetSet.combinations(languages: [.c, .cPlusPlus], targets: targets, targetVariants: targetVariants, standards: [.gnu11, .gnuPlusPlus17, .gnuPlusPlus20])
        let diagnostics = ModuleVerifierTargetSet.verifyTargets(targets: targets, targetVariants: targetVariants)

        let expectedCombinations: [ModuleVerifierTargetSet] = [
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "a-1", targetVariant: "a-2"),
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "a-2", targetVariant: "a-1"),
            ModuleVerifierTargetSet(language: .cPlusPlus, standard: .gnuPlusPlus17, target: "a-1", targetVariant: "a-2"),
            ModuleVerifierTargetSet(language: .cPlusPlus, standard: .gnuPlusPlus17, target: "a-2", targetVariant: "a-1"),
            ModuleVerifierTargetSet(language: .cPlusPlus, standard: .gnuPlusPlus20, target: "a-1", targetVariant: "a-2"),
            ModuleVerifierTargetSet(language: .cPlusPlus, standard: .gnuPlusPlus20, target: "a-2", targetVariant: "a-1"),
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "b-1", targetVariant: nil),
            ModuleVerifierTargetSet(language: .cPlusPlus, standard: .gnuPlusPlus17, target: "b-1", targetVariant: nil),
            ModuleVerifierTargetSet(language: .cPlusPlus, standard: .gnuPlusPlus20, target: "b-1", targetVariant: nil),
        ]
        let expectedDiagnostics: [Diagnostic] = []

        var extraCombinations = combinations
        var missingCombinations = expectedCombinations
        for expectedCombination in expectedCombinations {
            if let matchingIndex = extraCombinations.firstIndex(of: expectedCombination) {
                extraCombinations.remove(at: matchingIndex)
            }
        }
        for combination in combinations {
            if let matchingIndex = missingCombinations.firstIndex(of: combination) {
                missingCombinations.remove(at: matchingIndex)
            }
        }
        #expect(extraCombinations.isEmpty)
        #expect(missingCombinations.isEmpty)
        #expect(diagnostics == expectedDiagnostics)
    }

    @Test
    func badTargets() throws {
        let targets = ["a-1", "b-1", "b-2"]
        let targetVariants = ["a-2", "c-1"]
        var combinations = ModuleVerifierTargetSet.combinations(languages: [.c], targets: targets, targetVariants: targetVariants, standards: [.gnu11])
        var diagnostics = ModuleVerifierTargetSet.verifyTargets(targets: targets, targetVariants: targetVariants)

        let expectedCombinations: [ModuleVerifierTargetSet] = [
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "a-1", targetVariant: "a-2"),
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "a-2", targetVariant: "a-1"),
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "b-1", targetVariant: nil),
            ModuleVerifierTargetSet(language: .c, standard: .gnu11, target: "b-2", targetVariant: nil)
        ]
        var expectedDiagnostics: [Diagnostic] = [
            Diagnostic(behavior: .warning, location: .buildSettings(names: ["MODULE_VERIFIER_TARGET_TRIPLE_ARCHS"]), data: DiagnosticData("Duplicate target architectures found - b-1, b-2")),
            Diagnostic(behavior: .warning, location: .buildSettings(names: ["MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS"]), data: DiagnosticData("No matching target for target variant - c-1")),
        ]

        #expect(combinations == expectedCombinations)
        #expect(diagnostics == expectedDiagnostics)

        let languages: [ModuleVerifierLanguage] = [.c, .objectiveC]
        let standards: [ModuleVerifierLanguage.Standard] = [.cPlusPlus98, .gnuPlusPlus17]
        combinations = ModuleVerifierTargetSet.combinations(languages: languages, targets: targets, targetVariants: targetVariants, standards: standards)
        diagnostics = ModuleVerifierTargetSet.verifyLanguages(languages: languages, standards: standards)

        expectedDiagnostics = [
            Diagnostic(behavior: .error, location: .buildSettings(names: ["MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS", "MODULE_VERIFIER_SUPPORTED_LANGUAGES"]), data: DiagnosticData("No standard in \"c++98 gnu++17\" is valid for language c")),
            Diagnostic(behavior: .error, location: .buildSettings(names: ["MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS", "MODULE_VERIFIER_SUPPORTED_LANGUAGES"]), data: DiagnosticData("No standard in \"c++98 gnu++17\" is valid for language objective-c")),
        ]

        #expect(combinations.isEmpty)
        #expect(diagnostics == expectedDiagnostics)
    }
}
