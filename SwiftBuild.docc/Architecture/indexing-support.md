# Indexing Support

Swift Build, Xcode, and the low-level compilation tools work together to provide semantic functionality in the Xcode editor, like code-completion, jump-to-definition, global rename, etc.

## Overview

There are two forms of indexing in Xcode, both of which cooperatively utilize the (raw) Index Data Store in Derived Data.

- Index while Building
- Background Indexing

### Index while Building

Index-while-Building is controlled via the `INDEX_ENABLE_DATA_STORE` build setting and is enabled by default for debug builds, and the index store directory path is controlled by the `INDEX_DATA_STORE_DIR` setting.

When enabled, the index data store is populated by the compilers during the build process. The `-index-store-path` flag (both for clang and swiftc) indicates the directory root in which raw index data should be placed. The individual data files written by the compilers are not considered part of the build intermediates or outputs and therefore are not tracked by the dependency system.

> Note: The format and directory structure of the Index Data Store is an implementation detail of the compiler and indexing system. However, it's worth mentioning that the filenames of some of the files within the index data store are based on a hash of the absolute file path of the related translation unit. The compilers accept a `-index-unit-output-path` flag which can be used to base this hash on a relocatable path (which may or may not exist in the underlying filesystem). This is important for distributed systems where part of the raw index data may be generated on a remote server.

### Background Indexing

Background indexing uses the same raw data store, but uses dedicated build system APIs (see `generateIndexingInfo` and in `SWBBuildServiceSession`) to extract the compiler command line invocations that the build system would normally perform, and then re-invokes those command lines outside the context of the build system when appropriate, in order to achieve higher performance compared to performing a full build each time the raw index data store needs to be updated for a given translation unit.
