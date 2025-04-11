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
#if canImport(System)
    import System
#else
    import SystemPackage
#endif

import Foundation

#if canImport(ArgumentParserInternal)
    // remove once rdar://140831929 is resolved
    public import ArgumentParserInternal
#else
    public import ArgumentParser
#endif

import SWBCSupport
import SWBLibc

public func pbxcp_path_is_code_signed(_ path: Path) -> Bool {
    #if canImport(Darwin)
        do {
            return try xSecCodePathIsSigned(path)
        } catch {
            return false
        }
    #else
        return false
    #endif
}

public func pbxcp_path_is_staticOrObject(_ path: Path, fs: any FSProxy) -> Bool {
    let linkageType = (try? MachO(reader: BinaryReader(data: fs.read(path))).slicesIncludingLinkage().linkage)
    return linkageType == .static || linkageType == .macho(MachO.FileType.object)
}

fileprivate func xSecCodePathIsSigned(_ path: Path) throws -> Bool {
    #if os(macOS)
        var status: OSStatus = 0
        var staticCode: SecStaticCode?
        var csinfo: CFDictionary?

        let url = URL(fileURLWithPath: path.str)
        status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let staticCode else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1)
        }

        status = SecCodeCopySigningInformation(staticCode, [], &csinfo)
        guard status == 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let csinfo else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1)
        }

        guard let rawFlags = (csinfo as NSDictionary)[kSecCodeInfoFlags] as? UInt32 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        let flags = SecCodeSignatureFlags(rawValue: rawFlags)
        let isLinkerSigned = flags.contains(.linkerSigned)
        return !isLinkerSigned && (csinfo as NSDictionary)[kSecCodeInfoIdentifier] != nil
    #else
        throw StubError.error("xSecCodePathIsSigned is not supported on this platform")
    #endif
}

// FIXME: Move this fully to Swift Concurrency and execute the process via llbuild after PbxCp is fully converted to Swift
/// Spawns a process and waits for it to finish, closing stdin and redirecting stdout and stderr to fdout. Failure to launch, non-zero exit code, or exit with a signal will throw an error.
fileprivate func spawnTaskAndWait(_ launchPath: Path, _ arguments: [String]?, _ environment: Environment?, _ workingDirPath: String?, _ dryRun: Bool, _ stream: OutputByteStream) async throws {
    stream <<< launchPath.str
    for arg in arguments ?? [] {
        stream <<< " \(arg)"
    }
    stream <<< "\n"

    if dryRun {
        return
    }

    let (exitStatus, output) = try await Process.getMergedOutput(url: URL(fileURLWithPath: launchPath.str), arguments: arguments ?? [], currentDirectoryURL: workingDirPath.map { URL(fileURLWithPath: $0, isDirectory: true) }, environment: environment)

    // Copy the process output to the output stream.
    stream <<< "\(String(decoding: output, as: UTF8.self))"

    if !exitStatus.isSuccess {
        throw RunProcessNonZeroExitError(args: [launchPath.str] + (arguments ?? []), workingDirectory: workingDirPath, environment: environment ?? .init(), status: exitStatus, mergedOutput: ByteString(output))
    }
}

/// Copy `srcPath` to `dstPath` using the `strip` tool at `strip_tool_path` or `/usr/bin/strip` if one is not defined.
fileprivate func stripFile(_ srcPath: Path, _ dstPath: Path, _ strip_tool_path: Path?, _ strip_flags: String, _ strip_deterministic: Bool, _ dryRun: Bool, _ stream: OutputByteStream) async throws {
    var args = [String]()
    if strip_deterministic {
        args.append("-D")
    }
    args.append(contentsOf: strip_flags.split(separator: " ").map(String.init))
    args.append(srcPath.str)
    args.append("-o")
    args.append(dstPath.str)
    let toolPath = strip_tool_path ?? Path("/usr/bin/strip")
    try await spawnTaskAndWait(toolPath, args, nil, nil, dryRun, stream)
}

fileprivate func stripBitcodeFile(_ srcPath: Path, _ dstPath: Path, _ bitcode_strip_tool_path: Path?, _ bitcode_strip_flag: String, _ dryRun: Bool, _ stream: OutputByteStream) async throws {
    let toolPath = bitcode_strip_tool_path ?? Path("/usr/bin/bitcode_strip")
    // Note that srcPath and dstPath could be the same, in which case the file gets stripped in-place.
    let args = [srcPath.str, bitcode_strip_flag, "-o", dstPath.str]
    try await spawnTaskAndWait(toolPath, args, nil, nil, dryRun, stream)
}

fileprivate func isStrippable(_ first_four_bytes: UInt32, _ second_four_bytes: UInt32) -> Bool {
    switch first_four_bytes {
    case 0xCAFEBABE:
        #if _endian(big)
            // If we read the first 4 bytes as 0xCAFEBABE in big-endian, that means the order is 0xCA 0xFE 0xBA 0xBE in the file.
            // So we need to check if it looks like a Java .class file.  We do this by looking at the (big-endian) bytes 6 and 7,
            // which should be greater than or equal to 43 for any Java .class file.  This corresponds to either the low byte or
            // the high byte of the number of architectures in a Mach-O universal-binary wrapper (neither of which should be as
            // large as 43), so if the > 43 test fails then we assume it's a Mach-O file.  This will fail if we have a universal
            // binary with more than 42 architectures in it, but that's quite unlikely indeed...  this test should be good enough
            // for all practical purposes.
            if (second_four_bytes & 0xffff) >= 43 {
                return false
            }
        #endif
        return true
    case 0xBEBAFECA:
        #if _endian(little)
            // If we read the first 4 bytes as 0xBEBAFECA in little-endian, that means the order is 0xCA 0xFE 0xBA 0xBE in the file.
            // So we need to check if it looks like a Java .class file.  We do this by looking at the (big-endian) bytes 6 and 7,
            // which should be greater than or equal to 43 for any Java .class file.  This corresponds to either the low byte or
            // the high byte of the number of architectures in a Mach-O universal-binary wrapper (neither of which should be as
            // large as 43), so if the > 43 test fails then we assume it's a Mach-O file.  This will fail if we have a universal
            // binary with more than 42 architectures in it, but that's quite unlikely indeed...  this test should be good enough
            // for all practical purposes.
            if (((second_four_bytes >> 8) & 0xff00) | ((second_four_bytes >> 24) & 0x00ff)) >= 43 {
                return false
            }
        #endif
        return true
    case 0xFEEDFACE, 0xCEFAEDFE,
        0x213C6172, 0x72613C21,
        0xFEEDFACF, 0xCFFAEDFE:
        return true
    default:
        return false
    }
}

fileprivate func isMacho(_ path: Path) throws -> Bool {
    let src_fd = try FileDescriptor.open(FilePath(path.str), .readOnly)
    let ret = try src_fd.closeAfter { () throws -> Bool in
        return try withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { buffer in
            // Read the first chunk of data.  We're assuming we can get the entire Mach-O magic word (4 bytes) in a single read operation (a pretty safe assumption).
            let bytes_read = try src_fd.read(into: buffer)
            // If we're dealing with a Mach-O file and if we were asked to strip Mach-O files, we invoke 'strip' to perform the copy and strip the file (after closing the source file).
            return bytes_read >= 8 && isStrippable(buffer.load(fromByteOffset: 0, as: UInt32.self), buffer.load(fromByteOffset: 4, as: UInt32.self))
        }
    }
    return ret
}

fileprivate func textOutput(_ str: String, indentTo: Int, outStream: OutputByteStream) {
    outStream <<< "\(String(repeating: " ", count: indentTo * 3))\(str)\n"
}

/// Returns `true` if the file at `srcPath` should be stripped based on the strip flags which were passed.
fileprivate func shouldStripFile(_ srcPath: Path, _ srcParentPath: Path, _ verbose: Bool, _ strip_unsigned_binaries: Bool, _ entry_subpaths_to_strip: [Path], outStream: OutputByteStream) -> Bool {
    var should_strip = false

    // Walk entry_subpaths_to_strip to see if we should strip this specific subpath.
    // If so, then we will strip it regardless of whether it is signed (because we expect we wouldn't have been passed this subpath unless the invoker of PBXCp knew that it would be re-signed).
    for s in entry_subpaths_to_strip {
        let srcSubPath = srcPath.relativeSubpath(from: srcParentPath)
        if srcSubPath == s.normalize().str {
            // The end of srcPath matches the subpath to skip, so we want to strip it.
            should_strip = true
            break
        }
    }
    // If we haven't already decided to strip and strip_unsigned_binaries is true, then strip it if we can detect that it is unsigned.
    if !should_strip && strip_unsigned_binaries {
        if pbxcp_path_is_code_signed(srcPath) {
            outStream <<< "warning: not stripping binary because it is signed: \(srcPath.str)"
        } else {
            should_strip = true
        }
    }
    return should_strip
}

let code_sign_attributes = [
    "com.apple.cs.CodeDirectory",
    "com.apple.cs.CodeRequirements",
    "com.apple.cs.CodeSignature",
]

fileprivate func copyCodesignAttr(_ srcPath: Path, _ dstPath: Path) throws {
    let ext_attrs = try localFS.listExtendedAttributes(srcPath)
    for attr in ext_attrs {
        if code_sign_attributes.contains(attr) {
            try copyXattr(srcPath, dstPath, attr)
        }
    }
    return
}

fileprivate func copyXattr(_ srcPath: Path, _ dstPath: Path, _ xattrName: String) throws {
    guard let value = try localFS.getExtendedAttribute(srcPath, key: xattrName) else {
        return
    }
    try localFS.setExtendedAttribute(dstPath, key: xattrName, value: value)
}

fileprivate func copyResourceForkAndFinderInfo(_ srcPath: Path, _ dstPath: Path) throws {
    #if canImport(Darwin)
        // Copy over the Finder Info, if present.
        try copyXattr(srcPath, dstPath, XATTR_FINDERINFO_NAME)
        try copyXattr(srcPath, dstPath, XATTR_RESOURCEFORK_NAME)
    #endif
    return
}

fileprivate func removeTree(_ path: Path) throws {
    if localFS.isDirectory(path) {
        try localFS.removeDirectory(path)
    } else {
        try localFS.remove(path)
    }
}

fileprivate func copySymlink(_ srcPath: Path, _ dstPath: Path, dryRun: Bool, verbose: Bool, indentationLevel: Int, outStream: OutputByteStream) throws {
    if verbose {
        textOutput("copying symlink \(srcPath.basename)...", indentTo: indentationLevel, outStream: outStream)
    }
    // Read the contents of the symlink (i.e. its target path).
    let targetPath = try localFS.readlink(srcPath)
    if !dryRun {
        try localFS.symlink(dstPath, target: targetPath)
    }
    if verbose {
        textOutput(" -> \(targetPath.str)", indentTo: indentationLevel, outStream: outStream)
    }
}

fileprivate func copyRegular(_ srcPath: Path, _ srcParentPath: Path, _ dstPath: Path, options: CopyOptions, verbose: Bool, indentationLevel: Int, outStream: OutputByteStream) async throws {
    var didXferContents = false
    if try isMacho(srcPath) {
        if shouldStripFile(srcPath, srcParentPath, verbose, options.stripUnsignedBinaries, options.stripSubpaths, outStream: outStream) {
            if verbose {
                textOutput("copying and stripping \(srcPath.basename)...", indentTo: indentationLevel, outStream: outStream)
            }
            // Invoke 'strip' in a child process.  If it runs into problems, it will write error messages to out_err_fs.
            try await stripFile(srcPath, dstPath, options.stripTool, options.stripFlags, options.stripDeterministic, options.dryRun, outStream)
            // If we get here, all is well (we successfully stripped the Mach-O file).
            didXferContents = true
        }
        // If we need to strip bitcode from the file, then we either strip it in place (if we've already copied it), or use bitcode_strip to copy it.
        if let bitcodeStripFlag = options.bitcodeStripFlag {
            // If file was copied previously, so we strip bitcode in-place.
            let bitcodeStripSrcPath = didXferContents ? dstPath : srcPath
            if verbose {
                textOutput("\(didXferContents ? "": "copying and ")stripping bitcode from \(bitcodeStripSrcPath.basename)...", indentTo: indentationLevel, outStream: outStream)
            }
            // Invoke 'bitcode_strip' in a child process.  If it runs into problems, it will write error messages to out_err_fs.
            try await stripBitcodeFile(bitcodeStripSrcPath, dstPath, options.bitcodeStripToolPath, bitcodeStripFlag, options.dryRun, outStream)
            didXferContents = true
        }
    }
    if !didXferContents {
        if verbose {
            textOutput("copying \(srcPath.basename)...", indentTo: indentationLevel, outStream: outStream)
        }
        if !options.dryRun {
            try _copyFile(srcPath, dstPath)
        }
    }
    // Also copy HFS+ resource forks and Finder info, if appropriate.
    if options.preserveHfsData {
        try copyResourceForkAndFinderInfo(srcPath, dstPath)
    }
    try copyCodesignAttr(srcPath, dstPath)
}

func _copyFile(_ srcPath: Path, _ dstPath: Path) throws {
    do {
        var permissions: FilePermissions = [.ownerRead, .ownerWrite, .groupRead, .groupWrite, .otherRead, .otherWrite]
        if try localFS.isExecutable(srcPath) {
            permissions.insert([.ownerExecute, .groupExecute, .otherExecute])
        }
        let dstFd = try FileDescriptor.open(FilePath(dstPath.str), .writeOnly, options: [.create, .truncate], permissions: permissions)
        try dstFd.closeAfter {
            let srcFd = try FileDescriptor.open(FilePath(srcPath.str), .readOnly)
            try srcFd.closeAfter {
                let tmpBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 16, alignment: 1)
                defer { tmpBuffer.deallocate() }
                while true {
                    let bread = try srcFd.read(into: tmpBuffer)
                    if bread == 0 {
                        break
                    }
                    var bwritten: Int = 0
                    repeat {
                        let rebased = UnsafeRawBufferPointer(rebasing: tmpBuffer[bwritten..<bread])
                        bwritten += try dstFd.write(rebased)
                    } while (bread > bwritten)
                }
            }
        }
    } catch let error as Errno {
        throw POSIXError(error.rawValue, context: "copy", srcPath.str, dstPath.str)
    }
}

fileprivate func copyDirectory(_ srcPath: Path, _ srcTopLevelPath: Path, _ srcParentPath: Path, _ dstPath: Path, options: CopyOptions, verbose: Bool, indentationLevel: Int, outStream: OutputByteStream) async throws -> Int {
    if verbose {
        textOutput("copying \(srcPath.basename)/...", indentTo: indentationLevel, outStream: outStream)
    }
    // Create the destination directory.
    if !options.dryRun {
        try localFS.createDirectory(dstPath, recursive: false)
    }

    var num_files = 0
    next_dir_entry: for dirEntry in (try? localFS.listdir(srcPath)) ?? [] {

        let srcEntryPath = srcPath.join(dirEntry)
        // If there are any entries in 'includeOnlySubpaths' (which was populated by any -include_only_subpath options), then we only copy the following:
        //  - Entries which are directories which are ancestors of one of these subpaths.
        //  - Entries which are one of these subpaths.
        //  - If any entries which are one of these subpaths are directories, then descendants of those entries.
        // FIXME: rdar://111169903 We should change this logic (and the calling code in task construction) to be relative to srcParentPath instead, for consistency and to eliminate srcTopLevelPath.
        var shouldCopy = false
        if options.includeOnlySubpaths.count > 0 {
            for s in options.includeOnlySubpaths {
                let includeOnlySubpath = srcTopLevelPath.join(s)
                if includeOnlySubpath.isAncestor(of: srcEntryPath) || srcEntryPath.isAncestorOrEqual(of: includeOnlySubpath) {
                    shouldCopy = true
                    break
                }
            }
            if !shouldCopy {
                // We were unable to find a subpath which matches this path, so we continue to the next entry in the directory.
                continue next_dir_entry
            }
        }

        // Skip any entry which matches any subpath in 'excludeSubpaths' (which was populated by any -exclude_subpath options).
        // FIXME: rdar://111169903 We should change this logic (and the calling code in task construction) to be relative to srcParentPath instead, for consistency and to eliminate srcTopLevelPath.
        for s in options.excludeSubpaths {
            let pathToSkip = srcTopLevelPath.join(s)
            if pathToSkip.isAncestorOrEqual(of: srcEntryPath) {
                continue next_dir_entry
            }
        }

        // Skip any entry which matches a pattern in 'exclude' (which was populated by any -exclude options).
        // Each entry in 'entry_names_to_skip' is an fnmatch() pattern.
        for s in options.exclude {
            if let ret = try? SWBUtil.fnmatch(pattern: s, input: dirEntry) {
                if ret {
                    continue next_dir_entry
                }
            } else {
                throw StubError.error("fnmatch failed on pattern: \(s) with input : \(dirEntry).")
            }
        }

        let newDstPath = dstPath.join(dirEntry)

        // This entry is not to be skipped -- we copy it as appropriate.
        let ret = try await copyEntry(srcEntryPath, srcTopLevelPath, srcParentPath, newDstPath, options: options, verbose: options.VerboseSource, indentationLevel: indentationLevel + 1, outStream: outStream)
        num_files += ret
    }

    // Also copy HFS+ Finder info, if appropriate (directories don't have resource forks).
    if options.preserveHfsData {
        try copyResourceForkAndFinderInfo(srcPath, dstPath)
    }
    // Now we're done.
    return num_files
}

// Funnel function which recursively copies the given path.
fileprivate func copyEntry(_ srcPath: Path, _ srcTopLevelPath: Path, _ srcParentPath: Path, _ dstPath: Path, options: CopyOptions, verbose: Bool, indentationLevel: Int, outStream: OutputByteStream) async throws -> Int {
    let fileInfo = try localFS.getLinkFileInfo(srcPath)
    if fileInfo.isSymlink {
        try copySymlink(srcPath, dstPath, dryRun: options.dryRun, verbose: verbose, indentationLevel: indentationLevel, outStream: outStream)
        return 1
    } else if fileInfo.isFile {
        try await copyRegular(srcPath, srcParentPath, dstPath, options: options, verbose: verbose, indentationLevel: indentationLevel, outStream: outStream)
        if verbose {
            let size = fileInfo.statBuf.st_size
            textOutput(" \(size) bytes", indentTo: indentationLevel, outStream: outStream)
        }
        return 1
    } else if fileInfo.isDirectory {
        return try await copyDirectory(srcPath, srcTopLevelPath, srcParentPath, dstPath, options: options, verbose: verbose, indentationLevel: indentationLevel, outStream: outStream)
    } else {
        throw StubError.error("\(srcPath): unsupported or unknown stat mode (0x\(String(format: "%02x", fileInfo.statBuf.st_mode))")
    }
}

fileprivate func copyTree(_ srcPath: Path, _ dstPath: Path, options: CopyOptions, outStream: OutputByteStream) async -> Bool {
    if options.skipCopyIfContentsEqual {
        if FileManager.default.contentsEqual(atPath: srcPath.str, andPath: dstPath.str) {
            if options.verboseEntry {
                outStream <<< "note: skipping copy of '\(srcPath.str)' because it has the same contents as '\(dstPath.str)'\n"
            }
            return true
        }
    }

    // If the destination already exists, we first remove it.
    if localFS.exists(dstPath) {
        let _srcPath: Path
        let _dstPath: Path
        do {
            _srcPath = try localFS.realpath(srcPath)
        } catch let error as POSIXError {
            outStream <<< "error: \(srcPath.str): \(String(cString: strerror(error.code)))\n"
            return false
        } catch {
            outStream <<< "error: \(srcPath.str): \(error.localizedDescription)\n"
            return false
        }
        do {
            _dstPath = try localFS.realpath(dstPath)
        } catch let error as POSIXError {
            outStream <<< "error: \(dstPath.str): \(String(cString: strerror(error.code)))\n"
            return false
        } catch {
            outStream <<< "error: \(srcPath.str): \(error.localizedDescription)\n"
            return false
        }
        if _srcPath == _dstPath {
            outStream <<< "warning: '\(srcPath.str)' and '\(dstPath.str)' are identical (not copied)\n"
            return true
        }
        if _srcPath.isAncestor(of: _dstPath) {
            outStream <<< "error: destination '\(dstPath.str)' is inside source '\(srcPath.str)' (not copied)\n"
            return false

        } else if _dstPath.isAncestor(of: _srcPath) {
            outStream <<< "error: source '\(srcPath.str)' is inside destination '\(dstPath.str)' (not copied)\n"
            return false
        }
        do {
            try removeTree(dstPath)
        } catch {
            outStream <<< "error: remove failed \(error.localizedDescription)\n"
            return false
        }
    }

    // Compute the path to the parent directory of srcPath (excluding the trailing slash), so we can operate on subpaths relative to it.
    // Note that by the time we get here we already have validated that srcPath is not '/'.
    let parentPath = srcPath.dirname
    if parentPath == Path("") {
        outStream <<< "error: Unable to compute parent path for -> '\(srcPath.str)'\n"
        return false
    }
    do {
        try await _ = copyEntry(srcPath, srcPath, parentPath, dstPath, options: options, verbose: options.verboseEntry || options.VerboseSource, indentationLevel: 0, outStream: outStream)
    } catch {
        outStream <<< "error: \(error.localizedDescription)\n"
        return false
    }
    return true
}

struct CopyOptions: AsyncParsableCommand {
    static let _commandName: String = "builtin-copy"

    @Flag(name: .customLong("dry-run", withSingleDash: true), help: ArgumentHelp(visibility: .hidden))  // for testing
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "print a line of output for every source entry copied.")
    var VerboseSource = false

    @Flag(name: .shortAndLong, help: "print a line of output for every entry copied.")
    var verboseEntry = false

    @Flag(name: .customLong("preserve-hfs-data", withSingleDash: true), help: "preserves any HFS+ info, such as resource forks")
    var preserveHfsData: Bool = false

    @Flag(name: .customLong("skip-copy-if-contents-equal", withSingleDash: true), help: "exit without copying if the contents of <src> and <dst> are equal")
    var skipCopyIfContentsEqual: Bool = false

    @Flag(name: .customLong("resolve-src-symlinks", withSingleDash: true), help: "resolves the first level of any symlink source entries")
    var resolveSrcSymlinks: Bool = false

    @Flag(name: .customLong("rename", withSingleDash: true), help: "<dst> is a new name for <src>")
    var renaming: Bool = false

    @Flag(name: .customLong("ignore-missing-inputs", withSingleDash: true), help: "ignore missing <src>")
    var ignoreMissingInputs: Bool = false

    @Flag(name: .customLong("strip-unsigned-binaries", withSingleDash: true), help: "strips debug symbols from any executables")
    var stripUnsignedBinaries: Bool = false

    @Option(name: .customLong("strip-tool", withSingleDash: true), help: "path to strip tool; defaults to /usr/bin/strip")
    var stripTool = Path("/usr/bin/strip")

    @Option(name: .customLong("strip-flags", withSingleDash: true), help: "flags to pass to strip tool; defaults to -S -no_atom_info")
    var stripFlags: String = "-S -no_atom_info"

    @Flag(name: .customLong("strip-deterministic", withSingleDash: true), help: "runs the strip tool in deterministic (-D) mode")
    var stripDeterministic: Bool = false

    @Flag(name: .customLong("remove-static-executable", withSingleDash: true), help: "remove executables from copied bundles, if they are static libraries")
    var removeStaticExecutable: Bool = false

    @Option(name: .customLong("bitcode-strip-tool", withSingleDash: true))
    var bitcodeStripToolPath: Path? = nil

    @Option(name: .customLong("bitcode-strip", withSingleDash: true))
    var bitcodeStripFlag: String? = nil

    @Option(name: .customLong("exclude", withSingleDash: true), help: "skip entries matching <pattern>;  however, files passed as arguments are always copied")
    var exclude: [String] = []

    @Option(name: .customLong("exclude_subpath", withSingleDash: true), help: "skip the entry relative to <src>")
    var excludeSubpaths: [Path] = []

    @Option(name: .customLong("include_only_subpath", withSingleDash: true), help: "only copy the entry relative to <src>")
    var includeOnlySubpaths: [Path] = []

    @Option(name: .customLong("strip_subpath", withSingleDash: true), help: "strips debug symbols from the entry relative to <src>")
    var stripSubpaths: [Path] = []

    @Argument(help: "<src> [src, ...] <dst>")
    var paths: [String]

}

extension Path: ExpressibleByArgument {
    public init?(argument: String) {
        self = Path(argument)
    }
}

public func pbxcp(_ argv: [String], cwd: Path) async -> (success: Bool, output: String) {
    var options: CopyOptions
    do {
        var argv = argv
        argv.removeFirst()
        options = try CopyOptions.parse(argv)
    } catch {
        return (false, CopyOptions.message(for: error))
    }

    if options.paths.count == 1 {
        return (false, "error: %s: no destination directory specified\n")
    }

    if let bitcodeStripFlag = options.bitcodeStripFlag {
        // Always strip all bitcode if we were passed a valid option.
        if bitcodeStripFlag == "replace-with-marker" || bitcodeStripFlag == "all" {
            options.bitcodeStripFlag = "-r"
        } else {
            return (false, CopyOptions.helpMessage())
        }
    }
    let dst = options.paths.last!
    let srcPaths = Array(options.paths.dropLast())
    let outStream = OutputByteStream()
    for src in srcPaths {
        var dstPath = Path(dst)
        if !dstPath.isAbsolute {
            dstPath = cwd.join(dstPath)
        }

        // if not renaming we use the original src name (before we handle symlink resolving)
        if !options.renaming {
            if !src.hasSuffix(Path.pathSeparatorString) {
                dstPath = dstPath.join(Path(src).basename)
            }
        }
        var srcPath = Path(src).withoutTrailingSlash()

        // Resolve one level of symlink in the source, if appropriate.
        if options.resolveSrcSymlinks {
            if let resolvedSymlink = try? localFS.readlink(srcPath) {
                // If the contents of the symlink is a relative path, we need to prepend to it the path of the directory that contains the symlink
                // (if the path to the symlink has no slashes, it's in our current working directory, so we don't need to prepend anything at all).

                // Check if the contents of the symlink is a relative path and prepend the directory path if needed.
                if !resolvedSymlink.isAbsolute {
                    // Get the directory path that contains the symlink.
                    let symlinkDirectory = srcPath.dirname

                    // Append the relative path to the symlink directory path.
                    srcPath = symlinkDirectory.join(resolvedSymlink).normalize()
                } else {
                    srcPath = resolvedSymlink
                }
            }
        }

        // Do some sanity-checking.
        if srcPath.isRoot {
            outStream <<< "error: Invalid source path: '\(srcPath.str)'\n"
            return (false, outStream.bytes.asString)
        }

        if options.ignoreMissingInputs && !localFS.exists(srcPath) {
            outStream <<< "note: ignoring missing input '\(srcPath.str)'\n"
            continue
        }

        if options.removeStaticExecutable {
            let bundle = Bundle(path: srcPath.str)
            if let exePath = try? bundle?.executableURL?.filePath {
                if pbxcp_path_is_staticOrObject(exePath, fs: localFS) {
                    options.exclude.append(exePath.basename)
                }
            }
        }

        if await copyTree(srcPath, dstPath, options: options, outStream: outStream) == false {
            return (false, outStream.bytes.asString)
        }
    }
    return (true, outStream.bytes.asString)
}
