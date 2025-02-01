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

import SWBUtil
import SWBTestSupport
import Testing

@Suite(.performance)
fileprivate struct ArgumentSplittingPerfTests: PerfTests {
    @Test
    func commandLineEncodingPerformance() async {
        let fakeCommandLine = ["clang", "-x", "c-header", "-target", "x86_64-apple-macos13.0", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-fmodules", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-shorten-64-to-32", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-semicolon-before-method-body", "-iquote", "/tmp/Product-generated-files.hmap", "-I/tmp/Product-own-target-headers.hmap", "-I/tmp/Product-all-non-framework-target-headers.hmap", "-ivfsoverlay", "/tmp/ptmp/all-product-headers.yaml", "-iquote", "/tmp/Product-project-headers.hmap", "-I/tmp/derived-normal/x86_64", "-I/tmp/derived/x86_64", "-I/tmp/derived", "-c", "/tmp/prefix.h", "-MD", "-MT", "dependencies", "-MF", "/tmp/precomps/SharedPrecompiledHeaders/3269580220266067498/prefix.h.d", "-iquote", "/tmp/Product-generated-files.hmap", "-I/tmp/Product-own-target-headers.hmap", "-I/tmp/Product-all-non-framework-target-headers.hmap", "-ivfsoverlay", "/tmp/ptmp/all-product-headers.yaml", "-iquote", "/tmp/Product-project-headers.hmap", "-I/tmp/derived-normal/x86_64", "-I/tmp/derived/x86_64", "-I/tmp/derived", "-o", "/tmp/precomps/SharedPrecompiledHeaders/3269580220266067498/prefix.h.gch", "--serialize-diagnostics", "/tmp/precomps/SharedPrecompiledHeaders/3269580220266067498/prefix.h.dia"] + (0..<1000).map { "-DKIND_OF_LONG_PREPROCESSOR_DEFINE\($0)=1" }

        await measure {
            for _ in 1...100 {
                let codec = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .fullCommandLine)
                _ = codec.encode(fakeCommandLine)
            }
        }
    }
}
