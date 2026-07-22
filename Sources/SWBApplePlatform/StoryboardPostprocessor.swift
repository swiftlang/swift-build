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
public import SWBCore
public import SWBMacro

/// The storyboard postprocessor strips design-time content from a `.storyboardc` bundle that was added directly to a build phase (as opposed to one produced by the storyboard compiler), reducing its deployment size.
///
/// Its input is the unprocessed `wrapper.storyboardc` type, and its output is marked as the refined `wrapper.storyboardc.compiled` type so that the stripped bundle routes to the storyboard linker rather than being fed back into the postprocessor. See rdar://50701007.
public final class IBStoryboardPostprocessorSpec: GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.xcode.tools.ibtool.storyboard.postprocessor"

    override public func declaredOutputFileType(forOutputAt path: Path, _ cbc: CommandBuildContext) -> FileTypeSpec? {
        if path.fileExtension == "storyboardc" {
            return cbc.producer.lookupFileType(identifier: "wrapper.storyboardc.compiled")
        }
        return nil
    }
}
