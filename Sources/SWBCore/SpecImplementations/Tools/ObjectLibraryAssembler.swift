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

public final class ObjectLibraryAssemblerSpec : GenericLinkerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier: String = "org.swift.linkers.object-library-assembler"

    public override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        return delegate.taskActionCreationDelegate.createObjectLibraryAssemblerTaskAction()
    }
}
