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
import SwiftBuild
import Testing

@Suite
fileprivate struct TargetsTests {
    @Test(arguments: ProjectModel.Target.ProductType.allCases) func basicTargetEncoding(_ productType: ProjectModel.Target.ProductType) throws {
        let obj = ProjectModel.Target.example(productType)
        try testCodable(obj) { $0.signature = nil }
    }

    @Test func basicAggregateTargetEncoding() throws {
        try testCodable(ProjectModel.AggregateTarget.example)
    }
}

extension ProjectModel.Target {
    static func example(_ productType: ProductType) -> Self {
        switch productType {
        case .packageProduct:
            return Self(id: "MyTarget", productType: productType, name: "TargetName", productName: "")
        default:
            var target = Self(id: "MyTarget", productType: productType, name: "TargetName", productName: "Product Name")
            target.common.addCopyFilesBuildPhase { _ in .example }
            target.common.signature = "signature"
            target.common.customTasks = [.example]
            return target
        }
    }
}

extension ProjectModel.AggregateTarget {
    static var example: Self {
        return ProjectModel.AggregateTarget(
            id: "aggregate-id",
            name: "AggregateName",
            buildConfigs: [ProjectModel.BuildConfig.example],
            buildPhases: [ProjectModel.BuildPhase.headersExample],
            buildRules: [ProjectModel.BuildRule.example],
            dependencies: [ProjectModel.TargetDependency.example]
        )
    }
}
