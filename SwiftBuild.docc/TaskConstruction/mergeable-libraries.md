# Mergeable Libraries

Building dynamic libraries which can be merged into another binary to improve runtime performance.

## Overview

Mergeable libraries is a feature of the Apple linker (introduced in Xcode 15.0) which enables a dynamic library to be created as "mergeable", containing additional metadata so that it can be merged into another binary (similar to linking against a static library with `-all_load`), or still be treated as a dynamic library. This feature was written to support an application-space equivalent to the `dyld` shared cache in the OS, with the goal of providing a launch time improvement and/or a smaller memory footprint. (At time of writing the actual benefits are still being examined.)

## Automatically merged binaries

The main workflow to use mergeable libraries is to create an **automatically merged binary** target by enabling the build setting `AUTOMATICALLY_MERGE_DEPENDENCIES` on a framework or app target. (The framework form has sometimes been called an "umbrella framework", but this is unrelated to the existing umbrella framework concept already present in Apple platforms (Cocoa.framework, etc.)). Enabling this setting will behave differently in debug and release builds. (A "debug build" here is defined as one where either the `clang` or the `swiftc` debug format is "unoptimized" - `-O0` and `-Onone` respectively - and a release build is anything else. This is represented by a new build setting `IS_UNOPTIMIZED_BUILD`.)

In release builds:

* Immediate framework and dylib target dependencies of the merged binary target will be built as mergeable. (This trait does _not_ transitively carry over to their dependencies.)
* Those mergeable libraries will be merged into the merged binary.
* When those mergeable target products are embedded in either the merged binary product, or into a product containing the merged binary product (e.g. an app containing a merged binary framework), then their binaries will not be included in the embedded copy.

In debug builds:

* Immediate target dependencies of the merged binary target will be built normally, not as mergeable.
* The merged binary target will link dylibs produced by those dependencies to be reexported.
* When those target dependency products are embedded in either the merged binary product, or into a product containing the merged binary product, then their binaries will not be included in the embedded copy. (I.e., same as the release case.)
* Those target dependency products will also be copied into a special location in the merged binary product, but containing only their binary, and the merged binary product will have an additional `@rpath` into that location.

The goal of the debug workflow is to imitate the release workflow, but without the additional cost of creating the mergeable metadata and performing the merge of all of the libraries. This could someday change if the overhead of that work is determined to be small enough. This imitative behavior is intended to prevent developers from accidentally adding a dependency in their project to one of the mergeable libraries, and then wonder why that dependency causes the app to crash in release builds because the mergeable library is missing (since its content was merged into the merged binary).

## Implementation

Enabling `AUTOMATICALLY_MERGE_DEPENDENCIES` on a target does two things:

1. It enables `MERGEABLE_LIBRARY` on any immediate target dependencies of the target.
2. It enables `MERGE_LINKED_LIBRARIES` on the merged binary target.

Enabling `MERGEABLE_LIBRARY` on the dependencies is performed using the `superimposedParameters` property of `SpecializationParameters` in `DependencyResolution`. `TargetDependencyResolver.computeGraph()` applies these `superimposedParameters` to all qualifying instances of the target in the dependency closure, eliminating duplicates as a result of this imposition.

`MERGE_LINKED_LIBRARIES` changes how those libraries are linked and embedded, as discussed below.

A target which has `MERGEABLE_LIBRARY` enabled will also have `MAKE_MERGEABLE` enabled if this is a release build and the target has a `MACH_O_TYPE` of `mh_dylib`. It has no intrinsic effect on the target in a debug build, but is used by other targets to identify that the library should be treated as a mergeable library, whether or not is was built as mergeable.

A target which has `MAKE_MERGEABLE` enabled will be linked to add the mergeable metadata, by passing `-make_mergeable` to the linker.

A target which has `MERGE_LINKED_LIBRARIES` enabled will do several things. First, it will link its dependencies differently:

* Release build workflow: It will merge the products of any of its immediate dependencies which have `MAKE_MERGEABLE` enabled using the linker flags `-merge_framework`, `-merge-l` and similar.
* Debug build workflow: Any of its immediate dependencies which have `MERGEABLE_LIBRARY` enabled but _not_ `MAKE_MERGEABLE` will be linked with the linker flags `-reexport_framework`, `-reexport-l`, and similar.
* Targets without `MERGEABLE_LIBRARY` enabled will be linked normally (appropriate for static libraries, or dynamic libraries not to be built as mergeable).

Second, when a mergeable library is embedded into either the merged binary product itself (e.g., an app or a framework), or into another product which is itself embedding the merged binary product (e.g., an app embedding a merged binary framework), the embedded product will not include the binary. This is done with `PBXCp`'s `-exclude_subpath` option.

Finally, in the debug workflow, a mergeable library which does not have `MAKE_MERGEABLE` enabled will additionally be copied into a special directory in the merged binary product, but that copy will contain only the binary (and necessary code signing metadata). This is so the merged binary product can find these mergeable libraries - since they're not actually being merged into it - but nothing else can accidentally do so.

When a mergeable library is re-signed after being copied (and having either its binary removed, or having everything but its binary removed), `codesign` will be passed the `--generate-pre-encrypt-hashes` option, to force it to have a signature format compatible with recent iOS releases. (This behavior is something of a hack, and a more dedicated option to make codeless bundles work may be added to `codesign` in the future.)

## Manual creation & use

The "automatic" creation of a merged binary might not be what all projects want. If a project wants to manually select which dependencies are merged in, enable `MERGE_LINKED_LIBRARIES` on the merged binary target, and `MERGEABLE_LIBRARY` for only those dependencies which should be merged in.

This selective control can also be useful to exercise the mergeable workflow in debug builds, by setting `MAKE_MERGEABLE` in addition to `MERGEABLE_LIBRARY` on targets in their debug configurations.

## Known issues

Vendored mergeable libraries are not yet supported, as either XCFrameworks or as standalone vendored frameworks. <rdar://105298026>

There is not a way to build a target as mergeable but have a target which depends on it and which has `MERGE_LINKED_LIBRARIES` to _not_ merge it in, but to treat it as an ordinary dylib.

