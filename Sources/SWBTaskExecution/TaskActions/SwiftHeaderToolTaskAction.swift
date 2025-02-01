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
import SWBLibc
public import SWBCore

public final class SwiftHeaderToolTaskAction: TaskAction {
    /// The parsed command line options.
    private struct Options {
        /// Whether the current target only supports a single architecture.
        let single: Bool

        /// The input architectures and file paths.
        let inputs: [String: Path]

        /// The output file path.
        var output: Path

        init(_ task: any ExecutableTask) throws {
            let programName = "builtin-swiftHeaderTool"

            let argsIter = task.commandLineAsStrings.makeIterator()
            precondition(argsIter.next() == programName)

            var single: Bool?
            var inputs = [String: Path]()
            var output: Path?

            while true {
                guard let arg = argsIter.next() else { break }

                func absolutePath(_ path: Path) -> Path {
                    return path.isAbsolute ? path : task.workingDirectory.join(path)
                }

                func argParam() throws -> String {
                    guard let p = argsIter.next() else { throw StubError.error("Failed to parse arguments: \(arg) requires an argument") }
                    return p
                }

                func argParams(count: Int) throws -> [String] {
                    var args = [String]()
                    for _ in 0..<count {
                        guard let p = argsIter.next() else { throw StubError.error("Failed to parse arguments: \(arg) requires \(count) arguments") }
                        args.append(p)
                    }
                    return args
                }

                func setSingleOccurrence<T>(_ result: inout T?, _ getValue : @autoclosure () throws -> T) throws -> T {
                    guard result == nil else { throw StubError.error("Failed to parse arguments: expected a single \(arg) argument") }
                    let newResult = try getValue()
                    result = newResult
                    return newResult
                }

                switch arg {
                case "-single":
                    single = try setSingleOccurrence(&single, true)
                case "-arch":
                    let args = try argParams(count: 2)
                    let arch = args[0]
                    let path = args[1]
                    inputs[arch] = absolutePath(Path(path))
                case "-o":
                    output = try setSingleOccurrence(&output, absolutePath(Path(argParam())))
                default:
                    throw StubError.error("Unrecognized argument: \(arg)")
                }
            }

            guard let out = output, inputs.count > 0 else {
                throw StubError.error("usage: \(programName) [[-arch <arch> <input-file>] ...] -o <output-file>\n")
            }

            self.single = single ?? false
            self.inputs = inputs
            self.output = out
        }
    }

    public override init() {
        super.init()
    }

    override public class var toolIdentifier: String {
        return "swift-header-tool"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        do {
            let options = try Options(task)

            // If there's only a single architecture, don't add ifdefs.
            if options.single {
                if let path = options.inputs.values.only {
                    try executionDelegate.fs.write(options.output, contents: executionDelegate.fs.read(path))
                    return .succeeded
                } else {
                    outputDelegate.emitError("Multiple architectures are not supported on this target.")
                    return .failed
                }
            }

            // List of known archs and C preprocessor macros defined to '1' that indicate said archs.
            // Order is important because some macros may be defined for multiple architectures.
            //
            // The third field describes the "baseline" architecture variant that generally works
            // on a wider variety of processors but is otherwise ABI-compatible with the
            // architecture listed, and can be linked against code built for the architecture
            // listed. For example, code compiled as the baseline (x86_64) can build and link
            // against libraries built for x86_64h.
            let knownArchs = [
                ("arm64_32", "__ARM64_ARCH_8_32__", nil),
                ("arm64e", "__arm64e__", "arm64"),
                ("arm64", "__arm64__", nil),
                ("armv7k", "__ARM_ARCH_7K__", nil),
                ("armv7s", "__ARM_ARCH_7S__", nil),
                ("armv7", "__ARM_ARCH_7A__", nil),
                ("x86_64h", "__x86_64h__", "x86_64"),
                ("x86_64", "__x86_64__", nil),
                ("i386", "__i386__", nil)
            ]

            let unknownArchs = Set(options.inputs.keys).subtracting(knownArchs.map { $0.0 })
            if !unknownArchs.isEmpty {
                throw StubError.error("Unsupported Swift architectures: \(unknownArchs.sorted().joined(separator: ", "))")
            }

            var byteString = ByteString(encodingAsUTF8: "#if 0\n")
            for (arch, archMacro, baselineArchOpt) in knownArchs {
                guard let path = options.inputs[arch] else { continue }

                // When there exists a baseline architecture but there is no
                // input for it, use the macro for the baseline architecture.
                // By convention, it is always defined along with the macro
                // for the more specialized architecture. To continue the
                // x86-64 example above: if there is only x86_64h content but
                // no x86_64 content, use the x86_64 macro (__x86_64__) to
                // catch both cases. Otherwise, use the architecture macro
                // given.
                let macro: String
                if let baseLineArch = baselineArchOpt, options.inputs[baseLineArch] == nil, let baseLineMacro = knownArchs.first(where: { $0.0 == baseLineArch })?.1 {
                    macro = baseLineMacro
                } else {
                    macro = archMacro
                }

                byteString += ByteString(encodingAsUTF8: "#elif defined(\(macro)) && \(macro)\n")
                byteString += try executionDelegate.fs.read(path) + "\n"
            }
            byteString += ByteString(encodingAsUTF8: "#else\n")
            byteString += ByteString(encodingAsUTF8: "#error unsupported Swift architecture\n")
            byteString += ByteString(encodingAsUTF8: "#endif\n")

            try executionDelegate.fs.write(options.output, contents: byteString)

            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try super.init(from: deserializer)
    }
}
