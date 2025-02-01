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

#include "CLibRemarksHelper.h"

#include <stddef.h>
#include <stdint.h>

#if __has_include(<llvm-c/Remarks.h>) && !defined(SKIP_LLVM_REMARKS)
#define HAVE_REMARKS
#endif

// This is hacky: we can't include llvm-c/Remarks.h because the symbols are not weak_import there, so the compiler can remove the check and return 1.
// Note that the other symbols (which are actually used in OptimizationRemarks.swift) are not weak_import, but the library is weak linked, so it won't require them.
// And another (possible) issue with this approach is the fact that we're weak linking libRemarks to SWBCSupport.framework and SWBCore.framework, but the code in SWBCore is not checking the weak_imports itself (it's Swift, so it can't), but instead calling into SWBCSupport (here) to do that.
#ifdef HAVE_REMARKS
extern uint32_t LLVMRemarkVersion(void) __attribute__((weak_import));
#endif

bool isLibRemarksAvailable(void) {
#ifdef HAVE_REMARKS
    return &LLVMRemarkVersion != NULL;
#else
    return false;
#endif
}
