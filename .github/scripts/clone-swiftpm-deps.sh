#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See http://swift.org/LICENSE.txt for license information
## See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

SCHEME="${1:-}"
git clone --branch "$SCHEME" https://github.com/swiftlang/swift.git ../swift
ln -s "$GITHUB_WORKSPACE" ../swift-build
../swift/utils/update-checkout --clone --scheme "$SCHEME" \
  --skip-repository swift-build \
  --skip-repository llvm-project \
  --skip-repository swift-llvm-bindings \
  --skip-repository cmark \
  --skip-repository swift-async-algorithms \
  --skip-repository swift-log \
  --skip-repository swift-numerics \
  --skip-repository swift-stress-tester \
  --skip-repository swift-testing \
  --skip-repository swift-corelibs-xctest \
  --skip-repository swift-corelibs-foundation \
  --skip-repository swift-foundation-icu \
  --skip-repository swift-foundation \
  --skip-repository swift-corelibs-libdispatch \
  --skip-repository swift-corelibs-blocksruntime \
  --skip-repository swift-integration-tests \
  --skip-repository swift-xcode-playground-support \
  --skip-repository ninja \
  --skip-repository cmake \
  --skip-repository indexstore-db \
  --skip-repository sourcekit-lsp \
  --skip-repository swift-format \
  --skip-repository swift-installer-scripts \
  --skip-repository swift-docc \
  --skip-repository swift-lmdb \
  --skip-repository swift-docc-render-artifact \
  --skip-repository swift-docc-symbolkit \
  --skip-repository swift-markdown \
  --skip-repository swift-experimental-string-processing \
  --skip-repository swift-sdk-generator \
  --skip-repository wasi-libc \
  --skip-repository wasmkit \
  --skip-repository curl \
  --skip-repository libxml2 \
  --skip-repository zlib \
  --skip-repository brotli \
  --skip-repository mimalloc \
  --skip-repository boringssl
exit 0
