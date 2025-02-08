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
public import SWBUtil
import SWBMacro

open class CompilerSpec : CommandLineToolSpec, @unchecked Sendable {
    class public override var typeName: String {
        return "Compiler"
    }

    /// Non-custom instances should be parsed as GenericCompilerSpec instances.
    class public override var defaultClassType: (any SpecType.Type)? {
        return GenericCompilerSpec.self
    }

    /// Which language versions a compiler supports.
    @_spi(Testing) public let supportedLanguageVersions: [Version]

    public override init(_ parser: SpecParser, _ basedOnSpec: Spec?, isGeneric: Bool) {
        supportedLanguageVersions = parser.parseStringList("SupportedLanguageVersions")?.compactMap {
            do {
                return try Version($0)
            } catch {
                // FIXME: This should eventually become an error.
                parser.warning("Could not parse `SupportedLanguageVersions`: \(error)")
                return nil
            }
        } ?? []

        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        // We parse 'Architectures' with some special logic.
        switch parser.parseObject("Architectures") {
        case nil:
            // It's accepted if not defined, of course.
            break
        case .plString("$(VALID_ARCHS)")?:
            // If the value is exactly the string "$(VALID_ARCHS)" then we accept it for legacy reasons.
            break
        case let item?:
            // Otherwise, expect a string list.
            let _ = parser.parseItemAsStringList("Architectures", item)
        }
        parser.parseStringList("Languages")
        parser.parseBool("ShowOnlySelfDefinedProperties")
        parser.parseString("Vendor")
        parser.parseString("Version")
        parser.parseObject("LanguageVersionDisplayNames")

        super.init(parser, basedOnSpec, isGeneric: isGeneric)
    }

    convenience required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }
}

extension CompilerSpec {
    static func findToolchainBlocklists(_ producer: any CommandProducer, directoryOverride: Path?) -> [Path] {
        // Expect to find all blocklists in:
        // .../<toolchain>.xctoolchain/usr/local/lib/swift/blocklists
        var results: [Path] = []
        guard let blockListDirPath = directoryOverride ?? producer.toolchains.map({ $0.path.join("usr/local/lib/swift-build/blocklists") }).first(where: { localFS.exists($0) }) ?? producer.toolchains.map({ $0.path.join("usr/local/lib/xcbuild/blocklists") }).first(where: { localFS.exists($0) }) else {
            return []
        }

        do {
            try localFS.traverse(blockListDirPath) { currentFilePath in
                if currentFilePath.fileExtension == "yml" || currentFilePath.fileExtension == "yaml" || currentFilePath.fileExtension == "json" {
                    results.append(currentFilePath)
                }
            }
        } catch {}
        return results
    }

    static func getBlocklist<T: Codable>(type: T.Type, toolchainFilename: String, blocklistPaths: [Path], fs: any FSProxy, delegate: any TargetDiagnosticProducingDelegate) -> T? {
        let blocklistPath: Path
        if let toolchainBlocklistPath = blocklistPaths.first(where: { $0.basename == toolchainFilename }) {
            blocklistPath = toolchainBlocklistPath
        } else {
            return nil
        }

        do {
            return try JSONDecoder().decode(T.self, from: blocklistPath, fs: fs)
        } catch {
            delegate.remark("Failed to parse blocklist at \(blocklistPath)")
            return nil
        }
    }
}

protocol ProjectFailuresBlockList {
    var KnownFailures: [String] { get }
}

extension ProjectFailuresBlockList {
    func isProjectListed(_ scope: MacroEvaluationScope) -> Bool {
        // Check if this project is on the blocklist.
        let RC_ProjectName = scope.evaluate(BuiltinMacros.RC_ProjectName)
        if !RC_ProjectName.isEmpty, KnownFailures.contains(RC_ProjectName) {
            return true
        }
        let RC_BaseProjectName = scope.evaluate(BuiltinMacros.RC_BASE_PROJECT_NAME)
        if !RC_BaseProjectName.isEmpty, KnownFailures.contains(RC_BaseProjectName) {
            return true
        }
        let projectName = scope.evaluate(BuiltinMacros.PROJECT_NAME)
        return KnownFailures.contains(projectName)
    }
}

open class GenericCompilerSpec : CompilerSpec, @unchecked Sendable {
    required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: true)
    }
}
