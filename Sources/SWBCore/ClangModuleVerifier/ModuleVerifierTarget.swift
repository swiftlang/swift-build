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

public struct ModuleVerifierTarget: Equatable {
    public let value: String
    public var architecture: String? {
        value.components(separatedBy: "-").first
    }
    public var vendor: String? {
        value.components(separatedBy: "-").dropFirst().first
    }
    public var osAndVersion: String? {
        value.components(separatedBy: "-").dropFirst(2).first
    }
    public var environment: String? {
        value.components(separatedBy: "-").dropFirst(3).first
    }

    init(target: String) {
        self.value = target
    }
}

extension ModuleVerifierTarget {
    static func targets(from targets: [String]) -> [ModuleVerifierTarget] {
        return targets.map { ModuleVerifierTarget(target: $0) }
    }
}

public struct ModuleVerifierTargetSet: Equatable {
    public let language: ModuleVerifierLanguage
    public let standard: ModuleVerifierLanguage.Standard
    public let target: ModuleVerifierTarget
    public let targetVariant: ModuleVerifierTarget?

    public init(language: ModuleVerifierLanguage, standard: ModuleVerifierLanguage.Standard, target: ModuleVerifierTarget, targetVariant: ModuleVerifierTarget? = nil) {
        self.language = language
        self.standard = standard
        self.target = target
        self.targetVariant = targetVariant
    }
}

extension ModuleVerifierTargetSet {
    public init(language: ModuleVerifierLanguage, standard: ModuleVerifierLanguage.Standard, target: String, targetVariant: String?) {
        self.language = language
        self.target = ModuleVerifierTarget(target: target)
        if let targetVariant {
            self.targetVariant = ModuleVerifierTarget(target: targetVariant)
        } else {
            self.targetVariant = nil
        }
        self.standard = standard
    }

    public static func combinations(languages: [ModuleVerifierLanguage], targets: [String], targetVariants: [String], standards: [ModuleVerifierLanguage.Standard]) -> [ModuleVerifierTargetSet] {
        return ModuleVerifierTargetSet.combinations(languages: languages,
                                      targets: ModuleVerifierTarget.targets(from: targets),
                                      targetVariants: ModuleVerifierTarget.targets(from: targetVariants),
                                      standards: standards)
    }

    private static func combinations(languages: [ModuleVerifierLanguage], targets: [ModuleVerifierTarget], targetVariants: [ModuleVerifierTarget], standards: [ModuleVerifierLanguage.Standard]) -> [ModuleVerifierTargetSet] {
        var combinations: [ModuleVerifierTargetSet] = []

        var variants: [String: ModuleVerifierTarget] = [:]
        for variant in targetVariants {
            if let architecture = variant.architecture {
                variants[architecture] = variant
            }
        }

        let languagesAndStandards = languages.map { language in
            return (language, language.standards(from: standards))
        }

        for target in targets {
            if let architecture = target.architecture, let variant = variants[architecture] {
                for (language, standards) in languagesAndStandards {
                    for standard in standards {
                        combinations.append(ModuleVerifierTargetSet(language: language, standard: standard, target: target, targetVariant: variant))
                        combinations.append(ModuleVerifierTargetSet(language: language, standard: standard, target: variant, targetVariant: target))
                    }
                }
            } else {
                for (language, standards) in languagesAndStandards {
                    for standard in standards {
                        combinations.append(ModuleVerifierTargetSet(language: language, standard: standard, target: target, targetVariant: nil))
                    }
                }
            }
        }

        return combinations
    }
}

extension ModuleVerifierTargetSet {
    public static func verifyTargets(targets: [String], targetVariants: [String]) -> [Diagnostic] {
        return ModuleVerifierTargetSet.verifyTargets(targets: ModuleVerifierTarget.targets(from: targets),
                                        targetVariants: ModuleVerifierTarget.targets(from: targetVariants))
    }

    static func verifyTargets(targets: [ModuleVerifierTarget], targetVariants: [ModuleVerifierTarget]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        let partitionedTargets = ModuleVerifierTargetSet.partition(targets: targets)
        let partitionedTargetVariants = ModuleVerifierTargetSet.partition(targets: targetVariants)

        diagnostics += ModuleVerifierTargetSet.verifyDuplicateArchitecture(partitionedTargets: partitionedTargets)
        diagnostics += ModuleVerifierTargetSet.verifyDuplicateArchitecture(partitionedTargets: partitionedTargetVariants)

        diagnostics += ModuleVerifierTargetSet.verifyMatchingTargetForVariant(partitionedTargets: partitionedTargets, partitionedTargetVariants: partitionedTargetVariants)

        return diagnostics
    }

    private static func partition(targets: [ModuleVerifierTarget]) -> [String: [ModuleVerifierTarget]] {
        var partitionedTargets: [String: [ModuleVerifierTarget]] = [:]

        for target in targets {
            partitionedTargets[target.architecture ?? "", default: []].append(target)
        }

        return partitionedTargets
    }

    private static func verifyDuplicateArchitecture(partitionedTargets: [String: [ModuleVerifierTarget]]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for (_, targets) in partitionedTargets {
            if targets.count > 1 {
                diagnostics.append(Diagnostic(behavior: .warning, location: .buildSettings(names: ["MODULE_VERIFIER_TARGET_TRIPLE_ARCHS"]), data: DiagnosticData("Duplicate target architectures found - \(targets.map { $0.value }.joined(separator: ", "))")))
            }
        }

        return diagnostics
    }

    private static func verifyMatchingTargetForVariant(partitionedTargets: [String: [ModuleVerifierTarget]],
                                        partitionedTargetVariants: [String: [ModuleVerifierTarget]]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for (architecture, targetVariants) in partitionedTargetVariants {
            if partitionedTargets[architecture] == nil {
                diagnostics.append(Diagnostic(behavior: .warning, location: .buildSettings(names: ["MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS"]), data: DiagnosticData("No matching target for target variant - \(targetVariants.map { $0.value }.joined(separator: ", "))")))
            }
        }

        return diagnostics
    }

    public static func verifyLanguages(languages: [ModuleVerifierLanguage], standards: [ModuleVerifierLanguage.Standard]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        for language in languages {
            if language.standards(from: standards).isEmpty {
                let standardStrings = standards.map { $0.rawValue }.joined(separator: " ")
                diagnostics.append(Diagnostic(behavior: .error, location: .buildSettings(names: ["MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS", "MODULE_VERIFIER_SUPPORTED_LANGUAGES"]), data: DiagnosticData("No standard in \"\(standardStrings)\" is valid for language \(language.rawValue)")))
            }
        }
        return diagnostics
    }
}
