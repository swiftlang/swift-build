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

import SWBProtocol
import SWBUtil
public import SWBMacro

public final class BuildRule: ProjectModelItem {
    /// The build rule name.
    public let name: String

    /// The GUID of the build rule.
    public let guid: String

    public let inputSpecifier: BuildRuleInputSpecifier

    public let actionSpecifier: BuildRuleActionSpecifier

    init(_ model: SWBProtocol.BuildRule, _ pifLoader: PIFLoader) {
        // FIXME: Clean up the model within this class, once the legacy implementation dies.
        self.name = model.name
        self.guid = model.guid
        switch model.inputSpecifier {
        case .patterns(let value):
            switch value {
            case .string(let str):
                // Split the value into a list of patterns and then parse each one.
                // FIXME: <rdar://problem/29304140> Adopt the new API when it's available rather than doing this naive split.
                self.inputSpecifier = .patterns(str.split(separator: " ").map({ pifLoader.userNamespace.parseString(String($0)) }))
            case .stringList(let list):
                self.inputSpecifier = .patterns(list.map({ pifLoader.userNamespace.parseString($0) }))
            }
        case .fileType(let identifier):
            self.inputSpecifier = .fileType(identifier: identifier)
        }


        switch model.actionSpecifier {
        case .compiler(let identifier):
            self.actionSpecifier = .compiler(identifier: identifier)
        case .shellScript(let contents, let inputInfo, let inputFileLists, let outputInfo, let outputFileLists, let dependencyInfo, let runOncePerArchitecture):
            self.actionSpecifier = .shellScript(
                contents: contents,
                inputs: inputInfo.map { pifLoader.userNamespace.parseString($0) },
                inputFileLists: inputFileLists.map { pifLoader.userNamespace.parseString($0) },
                outputs: outputInfo.map {
                    BuildRuleOutputInfo(path: pifLoader.userNamespace.parseString($0.path), additionalCompilerFlags: $0.additionalCompilerFlags.map {
                        pifLoader.userNamespace.parseStringList($0)
                    } ?? pifLoader.userNamespace.parseLiteralStringList([]))
                },
                outputFileLists: outputFileLists.map { pifLoader.userNamespace.parseString($0) },
                dependencyInfo: DependencyInfoFormat.fromPIF(dependencyInfo, pifLoader: pifLoader),
                runOncePerArchitecture: runOncePerArchitecture
            )
        }
    }

    @_spi(Testing) public init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // The name is required.
        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)

        guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)

        let fileTypeIdentifier = try Self.parseValueForKeyAsString(PIFKey_BuildRule_fileTypeIdentifier, pifDict: pifDict)
        if fileTypeIdentifier == BuildRule_FileTypeIsPatternIdentifier {
            guard let filePatterns = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildRule_filePatterns, pifDict: pifDict) else {
                throw PIFParsingError.custom("BuildRule input file type is pattern, but no pattern string was defined")
            }

            // Split the file patterns into a list of patterns and then parse each one.
            // FIXME: <rdar://problem/29304140> Adopt the new API when it's available rather than doing this naive split.
            self.inputSpecifier = .patterns(filePatterns.split(separator: " ").map({ return pifLoader.userNamespace.parseString(String($0)) }))
        } else if !fileTypeIdentifier.isEmpty {
            self.inputSpecifier = .fileType(identifier: fileTypeIdentifier)
        } else {
            throw PIFParsingError.custom("BuildRule \(PIFKey_BuildRule_fileTypeIdentifier) is empty")
        }

        let compilerSpecificationIdentifier = try Self.parseValueForKeyAsString(PIFKey_BuildRule_compilerSpecificationIdentifier, pifDict: pifDict)
        if compilerSpecificationIdentifier == BuildRule_CompilerIsShellScriptIdentifier {
            guard let scriptContents = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildRule_scriptContents, pifDict: pifDict) else {
                throw PIFParsingError.custom("BuildRule compiler is shell script, but no script contents were defined")
            }

            let inputFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_BuildRule_inputFilePaths, pifDict: pifDict).map { return pifLoader.userNamespace.parseString($0) }

            let inputFileListPaths = (try Self.parseOptionalValueForKeyAsArrayOfStrings(PIFKey_BuildRule_inputFileListPaths, pifDict: pifDict) ?? []).map { return pifLoader.userNamespace.parseString($0) }

            let outputFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_BuildRule_outputFilePaths, pifDict: pifDict).map { return pifLoader.userNamespace.parseString($0) }

            let outputFileListPaths = (try Self.parseOptionalValueForKeyAsArrayOfStrings(PIFKey_BuildRule_outputFileListPaths, pifDict: pifDict) ?? []).map { return pifLoader.userNamespace.parseString($0) }


            // The output file compiler flags are optional.
            let outputFilesCompilerFlags: [MacroStringListExpression]?
            if let data = pifDict[PIFKey_BuildRule_outputFilesCompilerFlags] {
                // Each entry in the array is a list of values.
                guard case let .plArray(contents) = data else {
                    throw PIFParsingError.incorrectType(keyName: PIFKey_BuildRule_outputFilesCompilerFlags, objectType: Self.self, expectedType: "Array", destinationType: nil)
                }
                outputFilesCompilerFlags = try contents.map { flagData in
                    guard case let .plArray(value) = flagData else {
                        throw PIFParsingError.incorrectType(keyName: PIFKey_BuildRule_outputFilesCompilerFlags, objectType: Self.self, expectedType: "Array", destinationType: nil)
                    }
                    return try pifLoader.userNamespace.parseStringList(value.map { item -> String in
                        guard case let .plString(value) = item else {
                            throw PIFParsingError.incorrectType(keyName: PIFKey_BuildRule_outputFilesCompilerFlags, objectType: Self.self, expectedType: "String", destinationType: nil)
                        }
                        return value
                    })
                }
            } else {
                outputFilesCompilerFlags = nil
            }

            let dependencyInfo: DependencyInfoFormat?
            if let format = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildRule_dependencyFileFormat, pifDict: pifDict) as PIFDependencyFormatValue? {
                let dependencyFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_BuildRule_dependencyFilePaths, pifDict: pifDict).map({ return pifLoader.userNamespace.parseString($0) })

                switch format {
                case .dependencyInfo:
                    guard dependencyFilePaths.count == 1 else {
                        throw PIFParsingError.custom("BuildRule dependencyInfo dependency format expects 1 dependency file path, found \(dependencyFilePaths.count)")
                    }
                    dependencyInfo = .dependencyInfo(dependencyFilePaths[0])
                case .makefile:
                    guard dependencyFilePaths.count == 1 else {
                        throw PIFParsingError.custom("BuildRule makefile dependency format expects 1 dependency file path, found \(dependencyFilePaths.count)")
                    }
                    dependencyInfo = .makefile(dependencyFilePaths[0])
                case .makefiles:
                    dependencyInfo = .makefiles(dependencyFilePaths)
                }

            } else {
                dependencyInfo = nil
            }

            let runOncePerArchitecture = try Self.parseValueForKeyAsBool(PIFKey_BuildRule_runOncePerArchitecture, pifDict: pifDict, defaultValue: true)

            let outputFiles = outputFilePaths.enumerated().map { (i, expr) -> BuildRuleOutputInfo in
                if let flags = outputFilesCompilerFlags, i < flags.count {
                    return .init(path: expr, additionalCompilerFlags: flags[i])
                } else {
                    return .init(path: expr, additionalCompilerFlags: nil)
                }
            }

            self.actionSpecifier = .shellScript(contents: scriptContents, inputs: inputFilePaths, inputFileLists: inputFileListPaths, outputs: outputFiles, outputFileLists: outputFileListPaths, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        } else if !compilerSpecificationIdentifier.isEmpty {
            self.actionSpecifier = .compiler(identifier: compilerSpecificationIdentifier)
        } else {
            throw PIFParsingError.custom("BuildRule \(PIFKey_BuildRule_compilerSpecificationIdentifier) is empty")
        }
    }

    private var fileTypeIdentifier: String {
        switch self.inputSpecifier {
        case .fileType(let identifier):
            return identifier
        case .patterns:
            return BuildRule_FileTypeIsPatternIdentifier
        }
    }

    private var compilerSpecificationIdentifier: String {
        switch self.actionSpecifier {
        case .compiler(let identifier):
            return identifier
        case .shellScript:
            return BuildRule_CompilerIsShellScriptIdentifier
        }
    }

    public var description: String
    {
        return "\(type(of: self))<\(fileTypeIdentifier)->\(compilerSpecificationIdentifier)>"
    }
}

public enum BuildRuleInputSpecifier: Sendable {
    /// A list of file patterns to match the input file's path against, if the identifier is the pattern proxy.
    ///
    /// We would like to deprecate the ability to expand macros in the patterns, as it's unclear if many (or any) people use it.
    case patterns([MacroStringExpression])

    /// The file type identifier to match the input file's file type against.
    case fileType(identifier: String)
}

public struct BuildRuleOutputInfo: Sendable {
    /// The output file path, which may contain build setting references.
    public let path: MacroStringExpression

    /// The custom per-file compiler flags to apply to the output.
    public let additionalCompilerFlags: MacroStringListExpression?
}

// See also: SWBProtocol.ProjectModel.BuildRule.ActionSpecifier
public enum BuildRuleActionSpecifier: Sendable {
    /// The identifier of the compiler specification to use to process the input file.
    case compiler(identifier: String)

    /// Use a custom shell script to process the rule's inputs.
    ///
    /// - contents: The contents of the script to run to process the input file, if the compiler specification identifier is the script proxy.
    /// - inputs: The list of (additional) input file paths, which may contain build setting references.
    /// - inputFileLists: The list of xcfilelists that contains a list of additional input file paths
    /// - outputs: The list of pairs of output file path (which may contain build setting references) and list of per-file compiler flags.
    /// - outputFileLists: The list of xcfilelists that contains a list of additional output file paths
    /// - dependencyInfo: The dependency info.
    /// - runOncePerArchitecture: Run once per architecture/variant.
    case shellScript(contents: String,
                     inputs: [MacroStringExpression],
                     inputFileLists: [MacroStringExpression],
                     outputs: [BuildRuleOutputInfo],
                     outputFileLists: [MacroStringExpression],
                     dependencyInfo: DependencyInfoFormat?,
                     runOncePerArchitecture: Bool)
}

// MARK: Build rule constant strings


let BuildRule_FileTypeIsPatternIdentifier       = "pattern.proxy"
let BuildRule_CompilerIsShellScriptIdentifier   = "com.apple.compilers.proxy.script"
