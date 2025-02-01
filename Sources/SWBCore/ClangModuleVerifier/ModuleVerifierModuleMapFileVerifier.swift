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

public struct ModuleVerifierModuleMapFileVerifier {
    public static func verify(framework: ModuleVerifierFramework) -> (verifyPublic: Bool, verifyPrivate: Bool, diagnostics: [Diagnostic]) {
        var diagnostics: [Diagnostic] = []
        var verifyPublic = true
        var verifyPrivate = true

        if framework.hasPublicHeaders && framework.publicModuleMap == nil {
            diagnostics.append(self.moduleMapMissing(kind: .publicModule, framework: framework))
            verifyPublic = false
        }

        if framework.hasPrivateHeaders && framework.privateModuleMap == nil {
            diagnostics.append(self.moduleMapMissing(kind: .privateModule, framework: framework))
            verifyPrivate = false
        }

        if let publicModuleMap = framework.publicModuleMap {
            let publicDiagnostics = self.moduleMapCheck(moduleMapKind: .publicModule,
                                                        path: publicModuleMap.path,
                                                        hasHeaders: framework.hasPublicHeaders,
                                                        modulesCount: publicModuleMap.modulesHaveContents ? publicModuleMap.modules.count : 0)

            if publicDiagnostics.count > 0 {
                verifyPublic = false
                diagnostics.append(contentsOf: publicDiagnostics)
            }
        }

        if let privateModuleMap = framework.privateModuleMap {
            let privateDiagnostics = self.moduleMapCheck(moduleMapKind: .privateModule,
                                                         path: privateModuleMap.path,
                                                         hasHeaders: framework.hasPrivateHeaders,
                                                         modulesCount: privateModuleMap.modules.count)

            if privateDiagnostics.count > 0 {
                verifyPrivate = false
                diagnostics.append(contentsOf: privateDiagnostics)
            }
        }

        return (verifyPublic, verifyPrivate, diagnostics)
    }

    private static func moduleMapCheck(moduleMapKind:ModuleMapKind, path: Path, hasHeaders: Bool, modulesCount: Int) -> [Diagnostic] {
        // Xcode currently does not properly support a framework with only private headers being modularized
        // In order to make it work an empty module map has to be supplied which will throw a bunch of errors unless we bail early
        if moduleMapKind == .publicModule && !hasHeaders && modulesCount == 0 {
            return []
        }

        var diagnostics: [Diagnostic] = []

        if !hasHeaders {
            let message = "\(moduleMapKind.rawValue) module exists but no \(moduleMapKind.rawValue) headers"
            diagnostics.append(Diagnostic(behavior: .error, location: .path(path), data: DiagnosticData(message)))
        }
        if modulesCount == 0 {
            let message = "module map does not declare a module"
            diagnostics.append(Diagnostic(behavior: .error, location: .path(path), data: DiagnosticData(message)))
        }
        return diagnostics
    }

    private static func moduleMapMissing(kind: ModuleMapKind, framework: ModuleVerifierFramework) -> Diagnostic {
        let message = "module map is missing; there are \(kind.rawValue) headers but no module map"
        return Diagnostic(behavior: .warning, location: .path(ModuleVerifierModuleMap.preferredMap(kind, framework: framework)), data: DiagnosticData(message))
    }
}
