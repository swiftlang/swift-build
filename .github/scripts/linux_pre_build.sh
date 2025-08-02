#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2025 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See http://swift.org/LICENSE.txt for license information
## See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

set -e

if command -v apt-get >/dev/null 2>&1 ; then # bookworm, noble, jammy
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y

    # Build dependencies
    apt-get install -y libsqlite3-dev libncurses-dev

    # Debug symbols
    apt-get install -y libc6-dbg

    if [[ "$INSTALL_CMAKE" == "1" ]] ; then
        apt-get install -y cmake ninja-build
    fi

    # Android NDK
    dpkg_architecture="$(dpkg --print-architecture)"
    if [[ "$SKIP_ANDROID" != "1" ]] && [[ "$dpkg_architecture" == amd64 ]] ; then
        eval "$(cat /etc/lsb-release)"
        case "$DISTRIB_CODENAME" in
            bookworm|jammy)
                : # Not available
                ;;
            noble)
                apt-get install -y google-android-ndk-r26c-installer
                ;;
            *)
                echo "Unknown distribution: $DISTRIB_CODENAME" >&2
                exit 1
        esac
    else
        echo "Skipping Android NDK installation on $dpkg_architecture" >&2
    fi
elif command -v dnf >/dev/null 2>&1 ; then # rhel-ubi9
    dnf update -y

    # Build dependencies
    dnf install -y sqlite-devel ncurses-devel

    # Debug symbols
    dnf debuginfo-install -y glibc
elif command -v yum >/dev/null 2>&1 ; then # amazonlinux2
    yum update -y

    # Build dependencies
    yum install -y sqlite-devel ncurses-devel

    # Debug symbols
    yum install -y yum-utils
    debuginfo-install -y glibc
fi
