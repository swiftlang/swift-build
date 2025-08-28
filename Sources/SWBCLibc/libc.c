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

int swb_clibc_anchor(void);

// Stub method to avoid no debug symbol warning from compiler,
// and avoid a TAPI mismatch from compiler optimizations
// potentially removing profiling symbols.
int swb_clibc_anchor(void) {
    return 0;
}

#include <stdio.h>

extern FILE * const swb_stdout();
extern FILE * const swb_stderr();

#if defined(_WIN32)
__declspec(dllexport)
#endif
FILE * const swb_stdout() {
    return stdout;
}

#if defined(_WIN32)
__declspec(dllexport)
#endif
FILE * const swb_stderr() {
    return stderr;
}
