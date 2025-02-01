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

public import SWBProtocol
public import SWBMacro

public enum DependencyInfoFormat: Sendable {
    /// A Darwin linker style dependency info file.
    case dependencyInfo(MacroStringExpression)

    /// A '.d'-style Makefile.
    case makefile(MacroStringExpression)

    /// A list of multiple '.d'-style Makefiles.
    case makefiles([MacroStringExpression])
}


extension DependencyInfoFormat {
    public static func fromPIF(_ dependencyInfo: SWBProtocol.DependencyInfo?, pifLoader: PIFLoader) -> DependencyInfoFormat? {
        guard let dependencyInfo else {
            return nil
        }

        switch dependencyInfo {
        case .dependencyInfo(let path):
            return .dependencyInfo(pifLoader.userNamespace.parseString(path))
        case .makefile(let path):
            return .makefile(pifLoader.userNamespace.parseString(path))
        case .makefiles(let paths):
            return .makefiles(paths.map{ pifLoader.userNamespace.parseString($0) })
        }
    }
}
