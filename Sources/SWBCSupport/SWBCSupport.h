//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// This framework defines functionality for Swift Build which is not presently written in Swift for some reason.

#ifndef SWBCSUPPORT_H
#define SWBCSUPPORT_H

#if __has_include(<TargetConditionals.h>)
#include <TargetConditionals.h>
#endif

#ifndef __APPLE__
// Re-exported from readline
char *readline(const char *);
int add_history(const char *);
int read_history(const char *);
int write_history(const char *);
int history_truncate_file(const char *, int);
#endif

#include "CLibclang.h"
#include "CLibRemarksHelper.h"
#include "PluginAPI.h"
#include "PluginAPI_functions.h"
#include "PluginAPI_types.h"

#endif // SWBCSUPPORT_H
