# Swift Build

@Metadata {
   @TechnologyRoot
}

Swift Build is a high-level build system based on [llbuild](https://github.com/swiftlang/swift-llbuild) with great support for building Swift. It is used by Xcode to build Xcode projects and Swift packages. It can also be used as the Swift Package Manager build system in preview form when passing `--build-system swiftbuild`.

## Overview

Swift Build is structured in layers of framework targets, which is described in <doc:build-system-architecture>.

## Topics

### Architecture

- <doc:build-system-architecture>
- <doc:dynamic-tasks>
- <doc:indexing-support>
- <doc:swift-driver>

### Development

This section contains notes on developing Swift Build.

- <doc:build-debugging>
- <doc:test-development>
- <doc:test-development-project-tests>

### Core

This section describes selected subsystems of the core infrastructure of Swift Build.

- <doc:target-specialization>
- <doc:macro-evaluation>
- <doc:project-interchange-format>
- <doc:xcspecs>

### Task Construction

- <doc:discovered-dependencies>
- <doc:mutable-outputs>
- <doc:mergeable-libraries>
