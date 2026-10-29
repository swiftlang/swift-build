//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
import SWBMacro
import Foundation

public struct CASFSDescription: Codable {
    /// The default for how many levels of subdirectories are traversed inside a search path directory.
    public static let defaultSearchPathIngestionDepth = 1

    public let paths: [Path]
    public let roots: [Path]
    public let searchPaths: [Path]
    /// How many levels of subdirectories are traversed inside each of the `searchPaths` directories.
    /// With a depth of 1, a "<PATH>" search path will ingest "<PATH>/mymodule/myheader.h" but not "<PATH>/SomethingElse/whatever/header.h".
    public let searchPathIngestionDepth: Int

    public init(paths: [Path], roots: [Path], searchPaths: [Path], searchPathIngestionDepth: Int = defaultSearchPathIngestionDepth) {
        self.paths = paths
        self.roots = roots
        self.searchPaths = searchPaths
        self.searchPathIngestionDepth = searchPathIngestionDepth
    }
}

public struct IngestCASFSRootTaskPayload: TaskPayload {
    public let casOpts: CASOptions
    public let compilerLocation: LibSwiftDriver.CompilerLocation

    public init(
        casOpts: CASOptions,
        compilerLocation: LibSwiftDriver.CompilerLocation
    ) {
        self.casOpts = casOpts
        self.compilerLocation = compilerLocation
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(casOpts)
            serializer.serialize(compilerLocation)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.casOpts = try deserializer.deserialize()
        self.compilerLocation = try deserializer.deserialize()
    }
}

public final class IngestCASFSRootSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.ingest-casfs-root"

    public override var payloadType: (any TaskPayload.Type)? { return IngestCASFSRootTaskPayload.self }

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return IngestCASFSRootSpec(registry: registry)
    }

    public init(registry: SpecRegistry) {
        // FIXME: Clean up manual initialization of objects.
        let proxy = SpecProxy(identifier: Self.identifier, domain: "", path: Path(""), type: IngestCASFSRootSpec.self, classType: nil, basedOn: nil, data: ["ExecDescription": PropertyListItem("Create CASFS Root $(OutputRelativePath)")], localizedStrings: nil)
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        fatalError("unexpected direct invocation")
    }

    public func constructCASFSJsonTask(
        _ cbc: CommandBuildContext,
        _ delegate: any TaskGenerationDelegate,
        paths: [any PlannedNode],
        roots: [any PlannedNode],
        searchPaths: [Path],
        searchPathIngestionDepth: Int = CASFSDescription.defaultSearchPathIngestionDepth,
    ) {
        let casfs = CASFSDescription(paths: paths.map{$0.path}, roots: roots.map{$0.path}, searchPaths: searchPaths, searchPathIngestionDepth: searchPathIngestionDepth)
        do {
            let contents = try ByteString(JSONEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes]).encode(casfs))
            cbc.producer.writeFileSpec.constructFileTasks(cbc, delegate, contents: contents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        } catch {
            delegate.error(error)
        }
    }
}
