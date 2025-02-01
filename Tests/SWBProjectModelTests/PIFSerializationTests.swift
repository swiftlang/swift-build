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

import Testing
import SWBProjectModel

@Suite fileprivate struct PIFSerializationTests {
    @Test func documentationCatalogPIFFileReferenceFileType() throws {
        let pifProject = PIF.Project(
            id: "project-id",
            path: "some/path/to/project",
            projectDir: "ProjectDir",
            name: "ProjectName"
        )
        let fileReference = pifProject.mainGroup.addFileReference(path: "some/path/to/Something.docc")
        class TestSerializer: IDEPIFSerializer {
            func objectSignature(_ object: any IDEPIFObject) -> String {
                return "SomeSignature"
            }
        }
        let dict = fileReference.serialize(to: TestSerializer())
        #expect(dict["fileType"] as? String == "folder.documentationcatalog")
    }

    @Test func aggregateTargetDependencies() throws {
        let project = PIF.Project(
            id: "project-id",
            path: "some/path/to/project",
            projectDir: "ProjectDir",
            name: "ProjectName"
        )
        let standardTarget = project.addTarget(productType: .executable, name: "Exe", productName: "exe")
        let aggregateTarget = project.addAggregateTarget(name: "Agg")
        aggregateTarget.addDependency(on: standardTarget.id, platformFilters: Set(arrayLiteral: PIF.PlatformFilter(platform: "linux")))
        class TestSerializer: IDEPIFSerializer {
            func objectSignature(_ object: any IDEPIFObject) -> String {
                return "SomeSignature"
            }
        }

        // Serialize the aggregate target and check that nothing was lost.
        let targetDict = aggregateTarget.serialize(to: TestSerializer())
        let dependencies = try #require(targetDict["dependencies"] as? Array<Dictionary<String,Any>>)
        #expect(dependencies.count == 1)
        let firstDependency = try #require(dependencies.first)
        #expect(firstDependency["guid"] as? String == standardTarget.id)
        let platformFilters = try #require(firstDependency["platformFilters"] as? Array<Dictionary<String,Any>>)
        #expect(platformFilters.count == 1)
        let firstPlatformFilter = try #require(platformFilters.first)
        #expect(firstPlatformFilter["platform"] as? String == "linux")
    }

}
