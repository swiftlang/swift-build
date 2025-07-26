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

#include "POSIXShims.h"

// _GNU_SOURCE is required to expose the definitions of these recent POSIX additions in glibc on Linux
#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>

int swb_pipe2(int pipefd[2], int flags) {
#if defined(_WIN32) || defined(__APPLE__)
    int ret = pipe(pipefd);
#ifndef _WIN32
    if (ret != -1) {
        fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
        fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
    }
#endif
    return ret;
#else
    return pipe2(pipefd, flags);
#endif
}

int swb_dup3(int oldfd, int newfd, int flags) {
#if defined(_WIN32) || defined(__APPLE__)
    int ret = dup2(oldfd, newfd);
#ifndef _WIN32
    if (ret != -1) {
        fcntl(newfd, F_SETFD, FD_CLOEXEC);
    }
#endif
    return ret;
#else
    return dup3(oldfd, newfd, flags);
#endif
}
