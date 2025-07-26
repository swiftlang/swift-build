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

#ifndef SWBCSUPPORT_POSIXSHIMS_H
#define SWBCSUPPORT_POSIXSHIMS_H

int swb_pipe2(int pipefd[2], int flags);
int swb_dup3(int oldfd, int newfd, int flags);

#endif
