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

package import SWBUtil
import SWBTaskExecution
private import SWBLLBuild

package protocol BuildSystemCache: Sendable, KeyValueStorage where Key == Path, Value == SystemCacheEntry {
    func clearCachedBuildSystem(for key: Path)
}

extension HeavyCache: BuildSystemCache where Key == Path, Value == SystemCacheEntry {
    package func clearCachedBuildSystem(for key: SWBUtil.Path) {
        self[key] = nil
    }
}

package final class SystemCacheEntry: CacheableValue {
    /// Lock that must be held by the active operation using this cache entry.
    let lock = AsyncLockedValue(())

    /// The environment in use.
    var environment: [String: String]? = nil

    /// The build description in use by this system.
    var buildDescription: BuildDescription? = nil

    /// The adaptor for this system.
    var adaptor: OperationSystemAdaptor? = nil

    /// The QoS to use for the llbuild invocation.
    var llbQoS: SWBLLBuild.BuildSystem.QualityOfService? = nil

    /// The system to use.
    var system: SWBLLBuild.BuildSystem? = nil

    /// The file system mode associated to the build
    var fileSystemMode: FileSystemMode? = nil

    package var cost: Int {
        buildDescription?.taskStore.taskCount ?? 0
    }
}
