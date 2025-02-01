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

import struct Foundation.CharacterSet
import class Foundation.PropertyListDecoder
public import SWBUtil
public import SWBCore
public import SWBMacro

public protocol IbtoolCompilerSupport {
    /// Generate any needed --target-device arguments.
    func targetDeviceArguments(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [String]

    /// Generate any needed --minimum-deployment-target arguments.
    func minimumDeploymentTargetArguments(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [String]

    /// Get the string files paths and regions.
    func stringsFilesAndRegions(_ cbc: CommandBuildContext) -> [(stringsFile: Path, region: String)]
}

extension IbtoolCompilerSupport {
    public func targetDeviceArguments(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [String] {
        var targetDeviceArguments = [String]()
        let resourcesTargetedDeviceFamily = cbc.scope.evaluate(BuiltinMacros.RESOURCES_TARGETED_DEVICE_FAMILY)

        // If set, RESOURCES_TARGETED_DEVICE_FAMILY overrides any values found in TARGETED_DEVICE_FAMILY.  The command line arguments for RESOURCES_TARGETED_DEVICE_FAMILY is generated from the individual xcspecs.
        if resourcesTargetedDeviceFamily.isEmpty, let sdkVariant = cbc.producer.sdkVariant {
            for targetDevice in sdkVariant.evaluateTargetedDeviceFamilyBuildSetting(cbc.scope, cbc.producer.productType).effectiveDeviceNames {
                targetDeviceArguments += ["--target-device", targetDevice]
            }
        }
        return targetDeviceArguments
    }

    public func minimumDeploymentTargetArguments(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [String] {
        var minimumDeploymentTargetArguments = [String]()

        // FIXME: We could push a setting for this.
        var minDeploymentTarget = cbc.scope.evaluate(BuiltinMacros.RESOURCES_MINIMUM_DEPLOYMENT_TARGET)
        if minDeploymentTarget.isEmpty, let macro = cbc.producer.platform?.deploymentTargetMacro {
            minDeploymentTarget = cbc.scope.evaluate(macro)
        }
        if !minDeploymentTarget.isEmpty {
            minimumDeploymentTargetArguments += ["--minimum-deployment-target", minDeploymentTarget]
        }
        return minimumDeploymentTargetArguments
    }

    public func stringsFilesAndRegions(_ cbc: CommandBuildContext) -> [(stringsFile: Path, region: String)] {
        var result = [(Path, String)]()
        for ftb in cbc.inputs {
            if let buildFile = ftb.buildFile {
                if case .reference(let guid) = buildFile.buildableItem, case let variantGroup as VariantGroup = cbc.producer.lookupReference(for: guid) {
                    for ref in variantGroup.children {
                        if let fileRef = ref as? FileReference, let region = fileRef.regionVariantName {
                            if let fileType = cbc.producer.lookupFileType(reference: fileRef), let stringFileType = cbc.producer.lookupFileType(identifier: "text.plist.strings"), fileType.conformsTo(stringFileType) {
                                let absolutePath = cbc.producer.filePathResolver.resolveAbsolutePath(fileRef)
                                result.append((absolutePath, region))
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}

public struct DiscoveredIbtoolToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public let bundleVersion: Version?
    public let shortBundleVersion: Version?

    public var toolVersion: Version? {
        return bundleVersion
    }
}

public func discoveredIbtoolToolInfo(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, at toolPath: Path) async throws -> DiscoveredIbtoolToolSpecInfo {
    struct Static {
        static let toolNameKey = CodingUserInfoKey(rawValue: "toolName")!
    }

    struct CommonVersionInfo: Decodable {
        let bundleVersion: Version
        let shortBundleVersion: Version

        private enum CodingKeys: String, CodingKey {
            case bundleVersion = "bundle-version"
            case shortBundleVersion = "short-bundle-version"
        }

        init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bundleVersion = try Version(container.decode(String.self, forKey: .bundleVersion))
            shortBundleVersion = try Version(container.decode(String.self, forKey: .shortBundleVersion))
        }
    }

    struct ToolVersionInfo: Decodable {
        typealias ToolKey = String

        let details: CommonVersionInfo

        init(from decoder: any Swift.Decoder) throws {
            let toolName = decoder.userInfo[Static.toolNameKey] ?? ""
            let container = try decoder.container(keyedBy: ManualCodingKey.self)
            details = try container.decode(CommonVersionInfo.self, forKey: ManualCodingKey("com.apple.\(toolName).version"))
        }

        private struct ManualCodingKey: CodingKey {
            let stringValue: String
            let intValue: Int?

            init?(stringValue: String) {
                self.stringValue = stringValue
                self.intValue = Int(stringValue)
            }

            init?(intValue: Int) {
                self.intValue = intValue
                self.stringValue = String(intValue)
            }

            init(_ string: String) {
                self.stringValue = string
                self.intValue = nil
            }
        }
    }

    return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, [toolPath.str, "--version", "--output-format", "xml1"]) { executionResult in
        let decoder = PropertyListDecoder()
        decoder.userInfo[Static.toolNameKey] = toolPath.basename
        let versionInfo: ToolVersionInfo
        do {
            versionInfo = try decoder.decode(ToolVersionInfo.self, from: executionResult.stdout)
        } catch {
            throw StubError.error("Failed to decode version info for '\(toolPath.str)': \(error.localizedDescription) (stdout: '\(String(decoding: executionResult.stdout, as: UTF8.self))', stderr: '\(String(decoding: executionResult.stderr, as: UTF8.self))'")
        }

        return DiscoveredIbtoolToolSpecInfo(toolPath: toolPath, bundleVersion: versionInfo.details.bundleVersion, shortBundleVersion: versionInfo.details.shortBundleVersion)
    }
}

extension MacroEvaluationScope {
    public func ibtoolExecutablePath(lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> Path {
        return evaluate(BuiltinMacros.IBC_EXEC).nilIfEmpty ?? Path("ibtool")
    }
}
