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

// This is a stub spec type, used for gate tasks.
//
// FIXME: We shouldn't need this, but there are some hard coded assumptions about being able to serialize task types currently.
public final class GateSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.gate"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return GateSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        fatalError("unexpected call")
    }
}
