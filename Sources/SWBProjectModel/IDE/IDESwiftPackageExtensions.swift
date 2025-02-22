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

import SWBProtocol

public typealias PIFDict = [String: Any]

public protocol PIFRepresentable {

    /// Returns the PIF representation of the receiver, as a dictionary mapping strings to strings/arrays/dictionaries.
    func serialize(to serializer: any IDEPIFSerializer) -> PIFDict
}


extension PIF.Project : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        var dict : PIFDict = [
            PIFKey_guid: id,
            PIFKey_Project_name: name,
            PIFKey_Project_isPackage: isPackage ? "true" : "false" ,
            PIFKey_path: path,
            PIFKey_Project_projectDirectory: projectDir,
            PIFKey_buildConfigurations: buildConfigs.map{ $0.serialize(to: serializer) },
            PIFKey_Project_defaultConfigurationName: "Release",
            PIFKey_Project_groupTree: mainGroup.serialize(to: serializer),
            PIFKey_Project_targets: targets.compactMap{ $0.signature },
        ]

        if let developmentRegion {
            dict[PIFKey_Project_developmentRegion] = developmentRegion
        }

        return dict
    }
}

extension PIF.Group : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "group",
            PIFKey_guid: id,
            PIFKey_Reference_sourceTree: pathBase.asString,
            PIFKey_path: path,
            PIFKey_name: name ?? path,
            PIFKey_Reference_children: subitems.map{ ($0 as! (any PIFRepresentable)).serialize(to: serializer) }
        ]
    }
}

extension PIF.FileReference : PIFRepresentable {

    private func fileTypeIdentifier(for path: String) -> String {
        // FIXME: We need real logic here.  <rdar://problem/33634352> [SwiftPM] When generating PIF, we need a standard way to determine the file type
        let pathExtension = (path as NSString).pathExtension as String
        switch pathExtension {
        case "a":
            return "archive.ar"
        case "s", "S":
            return "sourcecode.asm"
        case "c":
            return "sourcecode.c.c"
        case "cl":
            return "sourcecode.opencl"
        case "cpp", "cp", "cxx", "cc", "c++", "C", "tcc":
            return "sourcecode.cpp.cpp"
        case "d":
            return "sourcecode.dtrace"
        case "defs", "mig":
            return "sourcecode.mig"
        case "m":
            return "sourcecode.c.objc"
        case "mm", "M":
            return "sourcecode.cpp.objcpp"
        case "metal":
            return "sourcecode.metal"
        case "l", "lm", "lmm", "lpp", "lp", "lxx":
            return "sourcecode.lex"
        case "swift":
            return "sourcecode.swift"
        case "y", "ym", "ymm", "ypp", "yp", "yxx":
            return "sourcecode.yacc"


        // FIXME: This is probably now more important because of resources support.
        case "xcassets":
            return "folder.assetcatalog"
        case "xcstrings":
            return "text.json.xcstrings"
        case "storyboard":
            return "file.storyboard"
        case "xib":
            return "file.xib"

        case "xcframework":
            return "wrapper.xcframework"

        case "docc":
            return "folder.documentationcatalog"

        case "rkassets":
            return "folder.rkassets"

        default:
            return SwiftBuildFileType.all.first{ $0.fileTypes.contains(pathExtension) }?.fileTypeIdentifier ?? "file"
        }
    }

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "file",
            PIFKey_guid: id,
            PIFKey_Reference_sourceTree: pathBase.asString,
            PIFKey_path: path,
            // FIXME: We need a real solution here (or: could we not omit the file type and let it be inferred?)
            PIFKey_Reference_fileType: fileType ?? fileTypeIdentifier(for: path)
        ]
    }
}

extension PIF.BaseTarget : PIFRepresentable {
    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        _serialize(to: serializer)
    }
}

extension PIF.PlatformFilter: PIFRepresentable {
    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        if environment.isEmpty {
            return [ "platform": platform ]
        } else {
            return [
                "platform": platform,
                "environment": environment,
            ]
        }
    }
}

extension PIF.HeadersBuildPhase : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "com.apple.buildphase.headers",
            PIFKey_guid: id,
            PIFKey_BuildPhase_buildFiles: files.map{ $0.serialize(to: serializer) },
        ]
    }
}

extension PIF.SourcesBuildPhase : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "com.apple.buildphase.sources",
            PIFKey_guid: id,
            PIFKey_BuildPhase_buildFiles: files.map{ $0.serialize(to: serializer) },
        ]
    }
}

extension PIF.FrameworksBuildPhase : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "com.apple.buildphase.frameworks",
            PIFKey_guid: id,
            PIFKey_BuildPhase_buildFiles: files.map{ $0.serialize(to: serializer) },
        ]
    }
}

extension PIF.CopyFilesBuildPhase : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "com.apple.buildphase.copy-files",
            PIFKey_guid: id,
            PIFKey_BuildPhase_buildFiles: files.map{ $0.serialize(to: serializer) },
            PIFKey_BuildPhase_destinationSubfolder: destinationSubfolder.pathString,
            PIFKey_BuildPhase_destinationSubpath: destinationSubpath,
            PIFKey_BuildPhase_runOnlyForDeploymentPostprocessing: (runOnlyForDeploymentPostprocessing ? "true" : "false"),
        ]
    }
}

extension PIF.ShellScriptBuildPhase : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "com.apple.buildphase.shell-script",
            PIFKey_guid: id,
            PIFKey_BuildPhase_name: name,
            PIFKey_BuildPhase_shellPath: shellPath,
            PIFKey_BuildPhase_scriptContents: scriptContents,
            PIFKey_BuildPhase_buildFiles: files.map{ $0.serialize(to: serializer) },
            PIFKey_BuildPhase_inputFilePaths: inputPaths,
            PIFKey_BuildPhase_outputFilePaths: outputPaths,
            PIFKey_BuildPhase_emitEnvironment: emitEnvironment ? "true" : "false",
            PIFKey_BuildPhase_sandboxingOverride: sandboxingOverride.valueForPIF,
            PIFKey_BuildPhase_alwaysOutOfDate: alwaysOutOfDate ? "true" : "false",
            PIFKey_BuildPhase_runOnlyForDeploymentPostprocessing: runOnlyForDeploymentPostprocessing ? "true" : "false",
            PIFKey_BuildPhase_originalObjectID: originalObjectID
        ]
    }
}

extension PIF.CopyBundleResourcesBuildPhase: PIFRepresentable {
    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_type: "com.apple.buildphase.resources",
            PIFKey_guid: id,
            PIFKey_BuildPhase_buildFiles: files.map{ $0.serialize(to: serializer) },
        ]
    }
}

extension PIF.BuildRule : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        var dict = PIFDict()
        dict[PIFKey_guid] = id
        dict[PIFKey_name] = name
        switch self.input {
        case .fileType(let typeId):
            dict[PIFKey_BuildRule_fileTypeIdentifier] = typeId
        case .filePattern(let pattern):
            dict[PIFKey_BuildRule_fileTypeIdentifier] = PIFKey_BuildRule_fileTypeIdentifier_pattern_proxy
            dict[PIFKey_BuildRule_filePatterns] = pattern
        }

        func populateDictFromShellScript(_ contents: String, inputPaths: [String], inputFileListPaths: [String]?, outputPaths: [String], outputFileListPaths: [String]?, outputFilesCompilerFlags: [String]?, dependencyInfo: PIF.BuildRule.Action.DependencyInfoFormat?, runOncePerArchitecture: Bool) {
            dict[PIFKey_BuildRule_compilerSpecificationIdentifier] = PIFKey_BuildRule_compilerSpecificationIdentifier_com_apple_compilers_proxy_script
            dict[PIFKey_BuildRule_scriptContents] = contents
            dict[PIFKey_BuildRule_inputFilePaths] = inputPaths
            dict[PIFKey_BuildRule_outputFilePaths] = outputPaths
            if let outputFilesCompilerFlags {
                dict[PIFKey_BuildRule_outputFilesCompilerFlags] = outputFilesCompilerFlags
            }
            if let dependencyInfo {
                let pifInfo: (format: String, paths: [String])
                switch dependencyInfo {
                case .dependencyInfo(let path):
                    pifInfo = (format: "dependencyInfo", paths: [path])
                case .makefile(let path):
                    pifInfo = (format: "makefile", paths: [path])
                case .makefiles(let paths):
                    pifInfo = (format: "makefiles", paths: paths)
                }
                dict[PIFKey_BuildRule_dependencyFileFormat] = pifInfo.format
                dict[PIFKey_BuildRule_dependencyFilePaths] = pifInfo.paths
            }
            dict[PIFKey_BuildRule_runOncePerArchitecture] = runOncePerArchitecture ? "true" : "false"
        }

        switch self.action {
        case .compiler(let specId):
            dict[PIFKey_BuildRule_compilerSpecificationIdentifier] = specId
        case .shellScriptWithFileList(let contents, let inputPaths, let inputFileListPaths, let outputPaths, let outputFileListPaths, let outputFilesCompilerFlags, let dependencyInfo, let runOncePerArchitecture):
            populateDictFromShellScript(contents, inputPaths: inputPaths, inputFileListPaths: inputFileListPaths, outputPaths: outputPaths, outputFileListPaths: outputFileListPaths, outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        }
        return dict
    }
}

extension PIF.CustomTask: PIFRepresentable {
    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        var dict = PIFDict()
        dict[PIFKey_CustomTask_commandLine] = self.commandLine
        dict[PIFKey_CustomTask_environment] = self.environment.compactMap { [$0.0, $0.1] }
        dict[PIFKey_CustomTask_workingDirectory] = self.workingDirectory
        dict[PIFKey_CustomTask_executionDescription] = self.executionDescription
        dict[PIFKey_CustomTask_inputFilePaths] = self.inputFilePaths
        dict[PIFKey_CustomTask_outputFilePaths] = self.outputFilePaths
        dict[PIFKey_CustomTask_enableSandboxing] = self.enableSandboxing ? "true" : "false"
        dict[PIFKey_CustomTask_preparesForIndexing] = self.preparesForIndexing ? "true" : "false"
        return dict
    }
}

extension PIF.BuildFile : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        switch self.ref {
        case .reference(let refId):
            var dict = PIFDict()
            dict[PIFKey_guid] = id
            dict[PIFKey_BuildFile_fileReference] = refId
            dict[PIFKey_BuildFile_headerVisibility] = headerVisibility?.rawValue
            dict[PIFKey_platformFilters] = platformFilters.map{ $0.serialize(to: serializer) }

            dict[PIFKey_BuildFile_codeSignOnCopy] = codeSignOnCopy ? "true" : "false"
            dict[PIFKey_BuildFile_removeHeadersOnCopy] = removeHeadersOnCopy ? "true" : "false"
            if let generatedCodeVisibility {
                let generatedCodeVisibilityValue: String
                switch generatedCodeVisibility {
                case .public:
                    generatedCodeVisibilityValue = "public"
                case .`private`:
                    generatedCodeVisibilityValue = "private"
                case .project:
                    generatedCodeVisibilityValue = "project"
                case .noCodegen:
                    generatedCodeVisibilityValue = "no_codegen"
                }
                dict[PIFKey_BuildFile_intentsCodegenVisibility] = generatedCodeVisibilityValue
            }

            if let resourceRule {
                dict[PIFKey_BuildFile_resourceRule] = resourceRule.rawValue
            }

            return dict
        case .targetProduct(let refId):
            return [
                PIFKey_guid: id,
                PIFKey_BuildFile_targetReference: refId,
                PIFKey_platformFilters: platformFilters.map{ $0.serialize(to: serializer) }
            ]
        }
    }
}

extension PIF.BuildConfig : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_guid: id,
            PIFKey_name: name,
            PIFKey_BuildConfiguration_buildSettings: settings.serialize(to: serializer),
            PIFKey_impartedBuildProperties: impartedBuildProperties.serialize(to: serializer) as Any,
        ]
    }
}

extension PIF.ImpartedBuildProperties : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        return [
            PIFKey_BuildConfiguration_buildSettings: settings.serialize(to: serializer),
        ]
    }
}

extension PIF.BuildSettings : PIFRepresentable {

    public func serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
        // Borderline hacky, but the main thing is that adding or changing a build setting does not require any changes to the property list representation code.  Using a hand-coded serializer might be more efficient but not even remotely as robust, and robustness is the key factor for this use case, as there aren't going to be millions of BuildSettings structs.
        var dict = PIFDict()
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            guard let name = child.label else {
                preconditionFailure("unnamed build settings are not supported")
            }
            switch child.value {
            case let value as String:
                if name == "_IOS_DEPLOYMENT_TARGET" {
                    dict["XROS_DEPLOYMENT_TARGET"] = value
                    break
                }
                dict[name] = value
            case let value as [String]:
                dict[name] = value
            default:
                // FIXME: I haven't found a way of distinguishing a value of an unexpected type from a value that is nil; they all seem to go through the `default` case instead of the `nil` case above.  Currently we will silently fail to serialize any struct field that isn't a `String` or a `[String]` (or an optional of either of those two).  This would only come up if a property of a type other than `String` or `[String]` were to be added to `BuildSettings`.
                continue
            }
        }
        for arg in platformSpecificSettings {
            // FIXME: Otherwise we get "Closure tuple parameter ... does not support destructuring"
            let (platformCondition, values) = arg
            for condition in platformCondition.asConditionStrings {
                for (key, value) in values {
                    // If `$(inherited)` is the only value, do not emit anything to the PIF.
                    if value == ["$(inherited)"] {
                        continue
                    }
                    dict["\(key.rawValue)[\(condition)]"] = value
                }
            }
        }
        return dict
    }
}
