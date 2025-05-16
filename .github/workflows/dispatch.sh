#!/bin/bash
apt-get update -y
apt-get install -y cmake ninja-build
cd /tmp && mkdir build
git clone https://github.com/apple/swift-corelibs-libdispatch
cd /tmp/swift-corelibs-libdispatch
#git checkout swift-6.0-RELEASE
cd /tmp
cmake -G Ninja \
        /tmp/swift-corelibs-libdispatch \
        -B /tmp/build \
        -DCMAKE_C_FLAGS=-fno-omit-frame-pointer \
        -DCMAKE_CXX_FLAGS=-fno-omit-frame-pointer \
        -DCMAKE_REQUIRED_DEFINITIONS=-D_GNU_SOURCE \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DENABLE_SWIFT=YES \
        -DCMAKE_C_COMPILER=/usr/bin/clang \
        -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib
cd /tmp/build && ninja install
rm -rf /tmp/build /tmp/swift-corelibs-libdispatch
apt-get remove -y cmake ninja-build
apt-get autoremove -y
rm -r /var/lib/apt/lists/*
