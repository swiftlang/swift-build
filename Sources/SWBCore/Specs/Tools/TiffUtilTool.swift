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

import SWBUtil
import SWBMacro

final class TiffUtilToolSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.compilers.tiffutil"

    private class func deferredSpec(_ cbc: CommandBuildContext) -> CommandLineToolSpec? {
        // When we get here, we either have a single-file group or a multi-file group as our input.  If it's a multi-file group then we definitely want to run tiffutil.  But if it's a single-file group, then we want to defer to the tool appropriate for the file type.
        //
        // FIXME: This is gross, but the way things currently work we can't detect during file grouping whether we have a single file or multiple files, we just have files which match the tiffutil spec.  We could potentially move this logic out of here and up into the FilesBasedBuildPhaseTaskProducer to examine the group and adjust the tool accordingly; that might make more sense, although it would require being able to mutate the group in that way.  This is somewhat related to <rdar://problem/34717923> Clean up handling of resource files in sources phase.  See also the FIXME comment above ImageScaleFactorsInputFileGroupingStrategy.
        // FIXME: For now we try and hack it up in a way that works for the main use case (COMBINE_HIDPI_IMAGES): <rdar://44623214&25099666> [Swift Build] Implement proper handling of grouped file output paths

        if let input = cbc.inputs.only {
            if let tiffFileType = cbc.producer.lookupFileType(identifier: "image.tiff"), input.fileType.conformsTo(tiffFileType) {
                return cbc.producer.copyTiffSpec
            } else if let pngFileType = cbc.producer.lookupFileType(identifier: "image.png"), input.fileType.conformsTo(pngFileType) {
                return cbc.producer.copyPngSpec
            } else {
                return cbc.producer.copySpec
            }
        }

        // We have a multi-file group, we don't defer to another spec, and call the generic mechanism to run tiffutil.
        return nil
    }

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        if let spec = Self.deferredSpec(cbc) {
            if let spec = spec as? CopyToolSpec {
                // CopyToolSpec is a special case because it expects the context to provide the output path,
                // rather than defining it on its own (it doesn't synthesize build rule).
                await spec.constructCopyTasks(cbc, delegate, ruleName: "CpResource")
            } else {
                await spec.constructTasks(cbc, delegate)
            }
        } else {
            await super.constructTasks(cbc, delegate)
        }
    }

    override func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        if let spec = Self.deferredSpec(cbc) {
            if spec is CopyToolSpec {
                return cbc.resourcesDir.map { resourcesDir in [(resourcesDir.join(cbc.input.absolutePath.basename), false)] } ?? []
            } else {
                return spec.evaluatedOutputs(cbc, delegate)
            }
        }

        return super.evaluatedOutputs(cbc, delegate)
    }

    override func lookup(_ macro: MacroDeclaration, _ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, _ lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> MacroExpression? {
        if macro == BuiltinMacros.OutputFileBase {
            // FIXME: Compute the destination path properly. We need the group identifier here, for now we try and hack it up in a way that works for the main use case (COMBINE_HIDPI_IMAGES): <rdar://problem/25099666> [Swift Build] Implement proper handling of grouped file output paths
            precondition(cbc.inputs.count > 1)
            return cbc.scope.namespace.parseLiteralString(cbc.inputs.first!.absolutePath.basenameWithoutSuffix.split("@").0)
        }

        return super.lookup(macro, cbc, delegate, lookup)
    }
}
