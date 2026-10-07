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

#if defined(__APPLE__)
#include <Availability.h>
#include <errno.h>
#include <unistd.h>

// `<Availability.h>` only defines `__MAC_27_0` once the SDK knows about an OS
// release which vends `pipe2` and `dup3`. When building against an older SDK,
// only the non-atomic fallback is compiled in; once the SDK is new enough, the
// atomic syscalls are used automatically on OSes which provide them.

static inline int swb_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags == -1) {
        return -1;
    }
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

// Creates a pipe with both ends marked close-on-exec. Uses the atomic
// `pipe2(O_CLOEXEC)` when built against an SDK which declares it (macOS 27 and
// aligned releases) and running on an OS which provides it; otherwise falls back
// to `pipe()` followed by `fcntl(F_SETFD, FD_CLOEXEC)`, which is not atomic with
// respect to a concurrent `fork()`. Returns 0, or -1 with `errno` set.
static inline int swb_pipe_cloexec(int fildes[_Nonnull 2]) {
#if defined(__MAC_27_0)
    if (__builtin_available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)) {
        return pipe2(fildes, O_CLOEXEC);
    }
#endif
    if (pipe(fildes) != 0) {
        return -1;
    }
    if (swb_set_cloexec(fildes[0]) != 0 || swb_set_cloexec(fildes[1]) != 0) {
        int savedErrno = errno;
        close(fildes[0]);
        close(fildes[1]);
        errno = savedErrno;
        return -1;
    }
    return 0;
}

// Duplicates `fildes` onto `fildes2` (as `dup2` would), marking the new
// descriptor close-on-exec. Uses the atomic `dup3(O_CLOEXEC)` when built against
// an SDK which declares it and running on an OS which provides it; otherwise
// falls back to `dup2()` followed by `fcntl(F_SETFD, FD_CLOEXEC)`. As with
// `dup3`, `fildes` must not equal `fildes2` (fails with `EINVAL` on either
// path). Returns `fildes2`, or -1 with `errno` set.
static inline int swb_dup3_cloexec(int fildes, int fildes2) {
#if defined(__MAC_27_0)
    if (__builtin_available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)) {
        return dup3(fildes, fildes2, O_CLOEXEC);
    }
#endif
    if (fildes == fildes2) {
        // Match dup3's behavior so callers see consistent semantics on either path.
        errno = EINVAL;
        return -1;
    }
    if (dup2(fildes, fildes2) < 0) {
        return -1;
    }
    if (swb_set_cloexec(fildes2) != 0) {
        int savedErrno = errno;
        close(fildes2);
        errno = savedErrno;
        return -1;
    }
    return fildes2;
}
#endif
