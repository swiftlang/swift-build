# Platform Support

Swift Build is designed to support host and target multiple platforms and has been designed from the ground up to support cross-compilation as a first class feature. Architecturally, _all_ builds are cross-compilation builds regardless of whether the host platform happens to be the same as the target platform.

## Plugins & Platforms

Support for various platforms and their unique product types, file types, compilers, and other behaviors, is separated from the core build business logic into a series of plugins. These plugins provide implementations of extension points (hooks) into various parts of the build process. This separation is a work in progress, and we aim to move more content into plugins over time.

### SWBAndroidPlatform

Contains support for targeting the Android platform, optionally using a Swift SDK if using Swift.

As a basis, the Android NDK is required to provide the platform sysroot, and therefore targeting Android is only supported on platforms supporting the Android NDK (as of 2025: Windows, macOS, and x86_64 Linux).

This does not currently support Android as a host platform (non-NDK path), but there is community interest in that.

### SWBApplePlatform

Contains support for targeting Apple platforms: macOS, iOS, tvOS, watchOS, visionOS, and DriverKit. Requires an Xcode or Command Line Tools installation on a macOS host to provide the actual SDKs.

### SWBGenericUnixPlatform

Contains support for targeting Linux, FreeBSD, and OpenBSD from any host platform, either using the host sysroot or a Swift SDK.

Note that there is no single definition of "Linux" - at this time, cross-compilation is only supported for Linux triples with a "gnu"-prefixed environment such as gnu or gnueabi, to avoid unintended overlap with Android or other Linux-based platforms. This will change over time as support for targeting various embedded platforms improves, and also needs to account for the Swift Static Linux SDK.

This plugin would also contain support for future Unix-like platforms which don't have a dedicated vendor-provided SDK or contain enough "special behaviors" from a build perspective to warrant a dedicated plugin (like Apple platforms, Android, and QNX). For example, NetBSD, Solaris, and so on. Ideally, platforms added here would first be [recognized as a platform](https://github.com/swiftlang/swift/blob/main/include/swift/AST/PlatformKinds.def) by the Swift language, though this is not a hard requirement.

### SWBQNXPlatform

Contains support for targeting the QNX platform.

As a basis, the QNX SDP is required, and therefore targeting QNX is only supported on platforms supporting the QNX SDP (as of QNX SDP 8: Windows and x86_64 Linux).

Swift has not been ported to QNX, so this currently only supports C/C++, and uses the qcc compiler instead of clang.

### SWBUniversalPlatform

Contains support for targeting platforms using a "none" triple, useful for bare metal development and various embedded devices.

Also contains support for build tools common to all platforms but which are still kept separate from the core build business logic to help enforce layering and decoupling.

### SWBWebAssemblyPlatform

Contains support for targeting the WebAssembly platform via Swift SDKs, from any host.

### SWBWindowsPlatform

Contains support for targeting the Windows platform using the MSVC ABI. Requires Visual Studio or Visual Studio Build Tools, and the Windows SDK. There is currently no support for other Windows ABIs such as MinGW or Cygwin.
