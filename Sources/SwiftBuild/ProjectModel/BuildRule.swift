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

extension ProjectModel {
    public struct BuildRule: Sendable, Hashable, Identifiable {
        public enum Input: Sendable, Hashable {
            case fileType(_ identifier: String)
            case filePattern(_ pattern: String)
        }

        public enum Action: Sendable, Hashable {
            case compiler(_ identifier: String)
            case shellScriptWithFileList(_ contents: String, inputPaths: [String], inputFileListPaths: [String], outputPaths: [String], outputFileListPaths: [String], outputFilesCompilerFlags: [String]?, dependencyInfo: DependencyInfoFormat?, runOncePerArchitecture: Bool)

            public enum DependencyInfoFormat: Sendable, Hashable {
                case dependencyInfo(String)
                case makefile(String)
                case makefiles([String])
            }
        }

        public let id: GUID
        public var name: String
        public var input: Input
        public var action: Action

        public init(id: GUID, name: String, input: Input, action: Action) {
            self.id = id
            self.name = name
            self.input = input
            self.action = action
        }
    }
}


extension ProjectModel.BuildRule: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = try container.decode([String: Value].self)
        guard let id = dict[PIFKey_guid]?.string,
              let name = dict[PIFKey_name]?.string,
              let typeId = dict[PIFKey_BuildRule_fileTypeIdentifier]?.string
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to find expected values")
        }
        self.id = ProjectModel.GUID(id)
        self.name = name

        if typeId == PIFKey_BuildRule_fileTypeIdentifier_pattern_proxy,
           let pattern = dict[PIFKey_BuildRule_filePatterns]?.string {
            self.input = .filePattern(pattern)
        } else {
            self.input = .fileType(typeId)
        }

        switch dict[PIFKey_BuildRule_compilerSpecificationIdentifier]?.string {
        case PIFKey_BuildRule_compilerSpecificationIdentifier_com_apple_compilers_proxy_script:
            guard let contents = dict[PIFKey_BuildRule_scriptContents]?.string,
                  let inputPaths = dict[PIFKey_BuildRule_inputFilePaths]?.array,
                  let outputPaths = dict[PIFKey_BuildRule_outputFilePaths]?.array
            else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Failed to decode proxy script information.")
            }

            let inputFileListPaths = dict[PIFKey_BuildRule_inputFileListPaths]?.array ?? []
            let outputFileListPaths = dict[PIFKey_BuildRule_outputFileListPaths]?.array ?? []

            let outputFilesCompilerFlags = dict[PIFKey_BuildRule_outputFilesCompilerFlags]?.array
            let runOncePerArchitecture = dict[PIFKey_BuildRule_runOncePerArchitecture]?.string == "true"

            let dependencyInfo: Action.DependencyInfoFormat?
            if let format = dict[PIFKey_BuildRule_dependencyFileFormat]?.string,
               let paths = dict[PIFKey_BuildRule_dependencyFilePaths]?.array {

                if format == "dependencyInfo" {
                    dependencyInfo = .dependencyInfo(paths[0])
                } else if format == "makefile" {
                    dependencyInfo = .makefile(paths[0])
                } else if format == "makefiles" {
                    dependencyInfo = .makefiles(paths)
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Failed to decode dependency info.")
                }
            } else {
                dependencyInfo = nil
            }

            self.action = .shellScriptWithFileList(contents, inputPaths: inputPaths, inputFileListPaths: inputFileListPaths, outputPaths: outputPaths, outputFileListPaths: outputFileListPaths, outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        case let .some(specId):
            self.action = .compiler(specId)
        case .none:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Failed to decode action information.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serialize())
    }

    private enum Value: Codable {
        case str(String)
        case arr([String])

        fileprivate var string: String? {
            switch self {
            case .str(let str): return str
            case .arr: return nil
            }
        }

        fileprivate var array: [String]? {
            switch self {
            case .str(_): return nil
            case .arr(let arr): return arr
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .str(let str): try str.encode(to: encoder)
            case .arr(let arr): try arr.encode(to: encoder)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                self = .str(str)
            } else if let arr = try? container.decode([String].self) {
                self = .arr(arr)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string or array in container.")
            }
        }
    }

    // TODO: fold this into 'encode'
    private func serialize() -> [String: Value] {
        var dict: [String: Value] = [:]
        dict[PIFKey_guid] = .str(id.value)
        dict[PIFKey_name] = .str(name)
        switch self.input {
        case .fileType(let typeId):
            dict[PIFKey_BuildRule_fileTypeIdentifier] = .str(typeId)
        case .filePattern(let pattern):
            dict[PIFKey_BuildRule_fileTypeIdentifier] = .str(PIFKey_BuildRule_fileTypeIdentifier_pattern_proxy)
            dict[PIFKey_BuildRule_filePatterns] = .str(pattern)
        }

        func populateDictFromShellScript(_ contents: String, inputPaths: [String], inputFileListPaths: [String]?, outputPaths: [String], outputFileListPaths: [String]?, outputFilesCompilerFlags: [String]?, dependencyInfo: Action.DependencyInfoFormat?, runOncePerArchitecture: Bool) {
            dict[PIFKey_BuildRule_compilerSpecificationIdentifier] = .str(PIFKey_BuildRule_compilerSpecificationIdentifier_com_apple_compilers_proxy_script)
            dict[PIFKey_BuildRule_scriptContents] = .str(contents)
            dict[PIFKey_BuildRule_inputFilePaths] = .arr(inputPaths)
            if let inputFileListPaths {
                dict[PIFKey_BuildRule_inputFileListPaths] = .arr(inputFileListPaths)
            }
            dict[PIFKey_BuildRule_outputFilePaths] = .arr(outputPaths)
            if let outputFileListPaths {
                dict[PIFKey_BuildRule_outputFileListPaths] = .arr(outputFileListPaths)
            }
            if let outputFilesCompilerFlags = outputFilesCompilerFlags {
                dict[PIFKey_BuildRule_outputFilesCompilerFlags] = .arr(outputFilesCompilerFlags)
            }
            if let dependencyInfo = dependencyInfo {
                let pifInfo: (format: String, paths: [String])
                switch dependencyInfo {
                case .dependencyInfo(let path):
                    pifInfo = (format: "dependencyInfo", paths: [path])
                case .makefile(let path):
                    pifInfo = (format: "makefile", paths: [path])
                case .makefiles(let paths):
                    pifInfo = (format: "makefiles", paths: paths)
                }
                dict[PIFKey_BuildRule_dependencyFileFormat] = .str(pifInfo.format)
                dict[PIFKey_BuildRule_dependencyFilePaths] = .arr(pifInfo.paths)
            }
            dict[PIFKey_BuildRule_runOncePerArchitecture] = runOncePerArchitecture ? .str("true") : .str("false")
        }

        switch self.action {
        case .compiler(let specId):
            dict[PIFKey_BuildRule_compilerSpecificationIdentifier] = .str(specId)
        case .shellScriptWithFileList(let contents, let inputPaths, let inputFileListPaths, let outputPaths, let outputFileListPaths, let outputFilesCompilerFlags, let dependencyInfo, let runOncePerArchitecture):
            populateDictFromShellScript(contents, inputPaths: inputPaths, inputFileListPaths: inputFileListPaths, outputPaths: outputPaths, outputFileListPaths: outputFileListPaths, outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        }
        return dict
    }
}

