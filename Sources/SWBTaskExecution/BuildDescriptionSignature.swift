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
@_spi(BuildDescriptionSignatureComponents) import SWBCore
package import SWBTaskConstruction
package import SWBUtil
import struct SWBProtocol.BuildDescriptionID

/// The type of the signature for a build description.
package typealias BuildDescriptionSignature = ByteString

/// Represents the components of a build description signature.
///
/// Any difference between two ``BuildDescriptionSignatureComponents`` instances indicates that the build description should be recomputed.
package struct BuildDescriptionSignatureComponents: Codable, Hashable, Sendable {
    enum BuildCommandCategory: Codable, Hashable, Sendable {
        case preprocess
        case assemble
        case other
    }

    struct TargetMetadata: Codable, Hashable, Sendable {
        let name: String
        let signature: String
        let buildParameters: BuildParameters
        let provisioningInputs: ProvisioningTaskInputs
        let macroConfigSignature: FilesSignature
        let specializeGuidForActiveRunDestination: Bool
    }

    struct ProjectMetadata: Codable, Hashable, Sendable {
        let name: String
        let macroConfigSignature: FilesSignature
    }

    struct SDKMetadata: Codable, Hashable, Sendable {
        let canonicalName: String
        let productBuildVersion: String?
    }

    let workspaceSignature: String
    let buildRequestParameters: BuildParameters
    let useParallelTargets: Bool
    let useImplicitDependencies: Bool
    let buildCommandCategory: BuildCommandCategory
    let enableStaleFileRemoval: Bool
    let targets: [TargetMetadata]
    let projects: [ProjectMetadata]
    let systemInfo: SystemInfo?
    let userInfo: UserInfo?
    let developerPath: Path
    let xcodeVersionString: String
    let xcodeProductBuildVersionString: String
    let buildServiceModTime: Date
    let sdkVersions: [SDKMetadata]

    fileprivate init(_ request: BuildPlanRequest) {
        workspaceSignature = request.workspaceContext.workspace.signature
        buildRequestParameters = request.buildRequest.parameters
        useParallelTargets = request.buildRequest.useParallelTargets
        useImplicitDependencies = request.buildRequest.useImplicitDependencies
        switch request.buildRequest.buildCommand {
        case .generatePreprocessedFile:
            buildCommandCategory = .preprocess
        case .generateAssemblyCode:
            buildCommandCategory = .assemble
        default:
            buildCommandCategory = .other
        }
        enableStaleFileRemoval = request.buildRequest.buildCommand.shouldEnableStaleFileRemoval
        targets = request.buildGraph.allTargets.map {
            TargetMetadata(
                name: $0.target.name,
                signature: $0.target.signature,
                buildParameters: $0.parameters,
                provisioningInputs: request.provisioningInputs(for: $0),
                macroConfigSignature: request.buildRequestContext.getCachedSettings($0.parameters, target: $0.target).macroConfigSignature,
                specializeGuidForActiveRunDestination: $0.specializeGuidForActiveRunDestination)
        }
        projects = request.workspaceContext.workspace.projects.map {
            ProjectMetadata(
                name: $0.name,
                macroConfigSignature: request.buildRequestContext.getCachedSettings(request.buildRequest.parameters, project: $0).macroConfigSignature)
        }
        systemInfo = request.workspaceContext.systemInfo
        userInfo = request.workspaceContext.userInfo
        developerPath = request.workspaceContext.core.developerPath.path
        xcodeVersionString = request.workspaceContext.core.xcodeVersionString
        xcodeProductBuildVersionString = request.workspaceContext.core.xcodeProductBuildVersionString
        buildServiceModTime = request.workspaceContext.core.buildServiceModTime

        // Add the ProductBuildVersion of installed SDKs, in case they are updated independently of Xcode
        sdkVersions = request.workspaceContext.core.sdkRegistry.allSDKs.sorted(by: \.canonicalName).map {
            SDKMetadata(canonicalName: $0.canonicalName, productBuildVersion: $0.productBuildVersion)
        }
    }
}

extension BuildDescriptionSignatureComponents {
    var humanReadableString: ByteString {
        get throws {
            try ByteString(JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(self))
        }
    }

    func signatureStringValue(humanReadableString: ByteString) -> BuildDescriptionSignature {
        let hashContext = InsecureHashContext()
        hashContext.add(bytes: humanReadableString)
        return hashContext.signature
    }
}

extension BuildDescriptionSignature {
    /// Compare data that is used to compute the build description signature of two build plan requests and return a string
    /// with the list of differences or `nil` if they are equal.
    static func compareBuildDescriptionSignatures(_ request: BuildPlanRequest, _ otherRequest: BuildPlanRequest, _ cacheDir: Path) throws -> (previousSignaturePath: Path, currentSignaturePath: Path)? {
        let requestComponents = BuildDescriptionSignatureComponents(request)
        let otherRequestComponents = BuildDescriptionSignatureComponents(otherRequest)
        if requestComponents == otherRequestComponents {
            return nil
        }

        let fs = request.workspaceContext.fs
        let tempDir = try fs.createTemporaryDirectory(parent: fs.realpath(Path.temporaryDirectory))

        func write(_ components: BuildDescriptionSignatureComponents, _ name: String) throws -> Path {
            let path = tempDir.join("\(name).signature")
            try request.workspaceContext.fs.write(path, contents: components.humanReadableString)
            return path
        }

        return try (
            previousSignaturePath: write(otherRequestComponents, "previous"),
            currentSignaturePath: write(requestComponents, "current")
        )
    }

    /// Returns the signature to use to cache a build description for a particular workspace and request.
    package static func buildDescriptionSignature(_ request: BuildPlanRequest, cacheDir: Path) throws -> BuildDescriptionSignature {
        let signatureComponents = BuildDescriptionSignatureComponents(request)
        let humanReadableString = try signatureComponents.humanReadableString
        let signature = signatureComponents.signatureStringValue(humanReadableString: humanReadableString)

        if request.workspaceContext.userPreferences.enableDebugActivityLogs {
            let detailsPath = BuildDescription.buildDescriptionPackagePath(inDir: cacheDir, signature: signature).join("description.signature")
            try request.workspaceContext.fs.createDirectory(detailsPath.dirname, recursive: true)
            try request.workspaceContext.fs.write(detailsPath, contents: humanReadableString)
        }

        return signature
    }

    /// Returns the signature to use for a build description for a particular build description ID.
    static func buildDescriptionSignature(_ buildDescriptionID: BuildDescriptionID) -> BuildDescriptionSignature {
        return BuildDescriptionSignature(encodingAsUTF8: buildDescriptionID.rawValue)
    }
}
