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

#if canImport(LLVM_C) && !SKIP_LLVM_REMARKS
public import Foundation
private import LLVM_C

/// The type of a remark.
public enum OptimizationRemarkType {
    case unknown, passed, missed, analysis, analysisFPCommute, analysisAliasing, failure

    fileprivate init(_ type: LLVMRemarkType) {
        switch type {
        case LLVMRemarkTypePassed:
            self = .passed
        case LLVMRemarkTypeMissed:
            self = .missed
        case LLVMRemarkTypeAnalysis:
            self = .analysis
        case LLVMRemarkTypeAnalysisFPCommute:
            self = .analysisFPCommute
        case LLVMRemarkTypeAnalysisAliasing:
            self = .analysisAliasing
        case LLVMRemarkTypeFailure:
            self = .failure
        default:
            self = .unknown
        }
    }
}

/**
 A remark entry used to give more insight into the compiler.
 */
public struct OptimizationRemark {
    /// The debug location that the remark is referring to.
    public struct DebugLoc {
        /// The path to the source file. Can be relative or absolute.
        public let sourceFilePath: String
        /// The line in the source file.
        public let sourceLine: UInt
        /// The column in the source file.
        public let sourceColumn: UInt

        fileprivate init(_ rawDebugLoc: LLVMRemarkDebugLocRef) {
            sourceFilePath = String(LLVMRemarkDebugLocGetSourceFilePath(rawDebugLoc))
            sourceLine = UInt(LLVMRemarkDebugLocGetSourceLine(rawDebugLoc))
            sourceColumn = UInt(LLVMRemarkDebugLocGetSourceColumn(rawDebugLoc))
        }
    }

    /**
     An argument is an arbitrary key-value entry that adds more information to the remark.

     Depending on the key, the value can be interpreted as a string, integer, etc.

     The debug location associated with the argument may refer to a separate location in the code.
     */
    public struct Arg {
        public let key: String
        public let value: String
        public let debugLoc: DebugLoc?

        fileprivate init(_ rawArg: LLVMRemarkArgRef) {
            key = String(LLVMRemarkArgGetKey(rawArg))
            value = String(LLVMRemarkArgGetValue(rawArg))
            if let rawDebugLoc = LLVMRemarkArgGetDebugLoc(rawArg) {
                debugLoc = OptimizationRemark.DebugLoc(rawDebugLoc)
            } else {
                debugLoc = nil
            }
        }
    }

    /// The type of the remark.
    public let type: OptimizationRemarkType

    /// The name of the pass that emitted the remark.
    public let passName: String

    /// The per-pass unique identifier of the remark. For example, a missing definition found by the inliner will have a remark name: "NoDefinition".
    public let remarkName: String

    /// The name of the function where the remark occurred. For C++, the mangled name is used. For Swift, the demangled name is used.
    public let functionName: String

    /// An optional debug source location that the remark is referring to.
    public let debugLoc: DebugLoc?

    /// The hotness of the code referenced by the remark, determined by compiler heuristics like PGO.
    public let hotness: UInt

    /// A list of key-value entries adding more information to the remark.
    public let args: [Arg]

    fileprivate init(_ rawEntry: LLVMRemarkEntryRef) {
        type = OptimizationRemarkType(LLVMRemarkEntryGetType(rawEntry))
        passName = String(LLVMRemarkEntryGetPassName(rawEntry))
        remarkName = String(LLVMRemarkEntryGetRemarkName(rawEntry))
        functionName = String(LLVMRemarkEntryGetFunctionName(rawEntry))
        if let rawDebugLoc = LLVMRemarkEntryGetDebugLoc(rawEntry) {
            debugLoc = DebugLoc(rawDebugLoc)
        } else {
            debugLoc = nil
        }
        hotness = UInt(LLVMRemarkEntryGetHotness(rawEntry))
        var mutableArgs: [Arg] = []
        let numArgs = LLVMRemarkEntryGetNumArgs(rawEntry)
        if numArgs != 0 {
            mutableArgs.reserveCapacity(Int(numArgs))
            var nextRawArg = LLVMRemarkEntryGetFirstArg(rawEntry)!
            mutableArgs.append(Arg(nextRawArg))
            while let rawArg = LLVMRemarkEntryGetNextArg(nextRawArg, rawEntry) {
                mutableArgs.append(Arg(rawArg))
                nextRawArg = rawArg
            }
            args = mutableArgs
        } else {
            args = []
        }
    }
}

extension OptimizationRemarkType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .passed:
            return "Passed"
        case .missed:
            return "Missed"
        case .analysis:
            return "Analysis"
        case .analysisFPCommute:
            return "Analysis (FP commute)"
        case .analysisAliasing:
            return "Analysis (aliasing)"
        case .failure:
            return "Failure"
        }
    }
}

extension OptimizationRemark.DebugLoc: CustomStringConvertible {
    public var description: String {
        return "\(sourceFilePath):\(sourceLine):\(sourceColumn)"
    }
}

extension OptimizationRemark.Arg: CustomStringConvertible {
    public var description: String {
        var desc = "\(key) : \(value)"
        if let loc = debugLoc {
            desc += " at \(loc)"
        }
        return desc
    }
}

extension OptimizationRemark: CustomStringConvertible {
    public var description: String {
        var desc = "\(type) remark: \(passName):\(remarkName) in \(functionName)"
        if let loc = debugLoc {
            desc += " at \(loc)"
        }
        if hotness > 0 {
            desc += " with hotness \(hotness)"
        }
        if !args.isEmpty {
            desc += "\nArgs:\n"
            for arg in args {
                desc += "- \(arg)\n"
            }
        }
        return desc
    }

    public var message: String {
        return args.reduce(String(), { result, arg in result + arg.value })
    }
}

extension String {
    fileprivate init(_ rawString: LLVMRemarkStringRef) {
        self = String(decoding: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: LLVMRemarkStringGetData(rawString)), count: Int(LLVMRemarkStringGetLen(rawString)), deallocator: Data.Deallocator.none), as: UTF8.self)
    }
}

public enum OptimizationRemarkParserFormat {
    case bitstream, yaml
}

public enum OptimizationRemarkParsingError: LocalizedError {
    case parsing(_ message: String)

    public var errorDescription: String? {
        switch self {
        case .parsing(let message):
            return message
        }
    }
}

fileprivate class OptimizationRemarkParser {
    private var rawParser: LLVMRemarkParserRef

    init(data: UnsafeRawBufferPointer, format: OptimizationRemarkParserFormat = .bitstream) throws {
        let rawParser: LLVMRemarkParserRef
        switch format {
        case .bitstream:
            rawParser = LLVMRemarkParserCreateBitstream(data.baseAddress, UInt64(data.count))
        case .yaml:
            rawParser = LLVMRemarkParserCreateYAML(data.baseAddress, UInt64(data.count))
        }
        self.rawParser = rawParser
    }

    deinit {
        LLVMRemarkParserDispose(rawParser)
    }

    private func getError() -> String? {
        if LLVMRemarkParserHasError(rawParser) == 0 {
            return nil
        }
        if let rawMessage = LLVMRemarkParserGetErrorMessage(rawParser) {
            return String(cString: rawMessage)
        }
        return "no error message"
    }

    public func readRemark() throws -> OptimizationRemark? {
        guard let entry = LLVMRemarkParserGetNext(rawParser) else {
            // If it's an error, throw it.
            if let error = getError() {
                throw OptimizationRemarkParsingError.parsing(error)
            }
            // If there is no error and no remark, it's the end of the file.
            return nil
        }

        defer { LLVMRemarkEntryDispose(entry) }

        // We have a remark entry.
        return OptimizationRemark(entry)
    }

    public func forEach(_ body: (OptimizationRemark) -> Void) throws {
        while let remark = try readRemark() {
            body(remark)
        }
    }

    public func readRemarks() throws -> [OptimizationRemark] {
        var result: [OptimizationRemark] = []
        try forEach { remark in
            result.append(remark)
        }
        return result
    }
}

extension Diagnostic {
    public init?(_ remark: OptimizationRemark, workingDirectory: Path) {
        guard let debugLoc = remark.debugLoc else { return nil } // skip if no debug location
        let path = Path(debugLoc.sourceFilePath)
        // Paths can be both absolute and relative to the working directory.
        let absolutePath = path.makeAbsolute(relativeTo: workingDirectory) ?? path
        self.init(behavior: .remark, location: .path(absolutePath, line: Int(debugLoc.sourceLine), column: Int(debugLoc.sourceColumn)), data: DiagnosticData(remark.message))
    }

    public static func remarks(forObjectPath objectFilePath: Path, fs: any FSProxy, workingDirectory: Path) throws -> [Diagnostic] {
        let object = try MachO(data: fs.read(objectFilePath))
        var result: [Diagnostic] = []
        for slice in try object.slices() {
            guard let bitstream = try slice.remarks() else { continue; } // skip if no remarks section

            try bitstream.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let parser = try OptimizationRemarkParser(data: ptr, format: .bitstream)
                try parser.forEach { remark in
                    guard let diagnostic = Diagnostic(remark, workingDirectory: workingDirectory) else { return }
                    result.append(diagnostic)
                }
            }
        }
        return result
    }
}

#else

extension Diagnostic {
    public static func remarks(forObjectPath objectFilePath: Path, fs: any FSProxy, workingDirectory: Path) throws -> [Diagnostic] {
        throw StubError.error("Swift Build was not compiled with support for LLVM optimization remarks")
    }
}

#endif
