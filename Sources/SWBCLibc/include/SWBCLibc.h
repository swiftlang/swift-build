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

#if defined(__linux__) && !defined(__ANDROID__)
#include <fcntl.h>
#include <fnmatch.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>

typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;

int dladdr(void *addr, Dl_info *info);
#endif

#if !defined(_WIN32)
#include <fcntl.h>

// Duplicates `fd` onto the lowest-numbered unused file descriptor, atomically
// setting the close-on-exec flag. Unlike a `dup()` followed by a separate
// `fcntl(F_SETFD, FD_CLOEXEC)`, this cannot race against a concurrent
// `fork()`/`exec()` in another thread. Returns the new descriptor, or -1 with
// `errno` set.
static inline int swb_dup_cloexec(int fd) {
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
}
#endif
