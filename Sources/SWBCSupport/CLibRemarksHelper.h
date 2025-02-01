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

#ifndef CLibRemarksHelper_h
#define CLibRemarksHelper_h

#include <stdbool.h>

// Swift has no way of checking if a weak_import symbol is available.
// This function checks if LLVMRemarkVersion from libRemarks.dylib is available, which should be enough to assert the whole library is available as well.
bool isLibRemarksAvailable(void);

#endif /* CLibRemarksHelper_h */
