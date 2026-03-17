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

import SWBMacro
import SWBUtil

extension CommandBuildContext {
    var toolchainHostEnvironment: Environment {
        var env = Environment()
        if producer.hostOperatingSystem == .windows {
            // On Windows, the Swift compiler needs additional entries in PATH to find its dependent DLLs, as there is no rpath equivalent.
            // The way this is computed is a little fragile, since when targeting Android we synthesize a toolchain pointing into the NDK,
            // which ends up being at the front of the list, so we find the first toolchain that's in a subdirectory of the DEVELOPER_DIR
            // (the Swift installation path) and use it to determine the toolchain path and version.
            let developerDir = scope.evaluate(BuiltinMacros.DEVELOPER_DIR)
            for toolchain in producer.toolchains where developerDir.isAncestor(of: toolchain.path) {
                env.appendPath(key: .path, value: toolchain.path.join("usr").join("bin").str) // is this one actually needed?
                env.appendPath(key: .path, value: developerDir.join("Runtimes").join(toolchain.version.description).join("usr").join("bin").str)
                env.appendPath(key: .path, value: scope.evaluate(BuiltinMacros.PATH))
                break
            }

            for tmpdir in ["TMP", "TEMP", "TMPDIR"] as [EnvironmentKey] {
                env[tmpdir] = scope.evaluate(BuiltinMacros.OBJROOT).str
            }

            #if os(Windows)
            do {
                // Necessary for temporary directory creation functions to work in subprocesses, among other things
                env["SystemRoot"] = try SWB_GetWindowsDirectoryW()
            } catch {
                assertionFailure("GetWindowsDirectoryW should not fail")
            }
            #endif
        }
        return env
    }
}

extension Environment {
    init(_ environment: [(String, String)]) {
        self.init(Dictionary(uniqueKeysWithValues: environment))
    }
}

extension Array where Element == (String, String) {
    init(_ environment: Environment) {
        self = Dictionary(environment).sorted(byKey: <).map { ($0.key, $0.value) }.nilIfEmpty ?? []
    }
}
