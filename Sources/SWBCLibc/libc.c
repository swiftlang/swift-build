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

#if defined(__APPLE__)
#include <Availability.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int swb_pipe_cloexec(int fildes[2]);
int swb_dup3_cloexec(int fildes, int fildes2);

// `<Availability.h>` only defines `__MAC_27_0` once the SDK knows about an OS
// release which vends `pipe2` and `dup3`. When building against an older SDK,
// only the non-atomic fallback is compiled in; once the SDK is new enough, the
// atomic syscalls are used automatically on OSes which provide them.

static int swb_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags == -1) {
        return -1;
    }
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

int swb_pipe_cloexec(int fildes[2]) {
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

int swb_dup3_cloexec(int fildes, int fildes2) {
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
