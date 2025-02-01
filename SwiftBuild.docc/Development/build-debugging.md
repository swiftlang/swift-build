# Build Debugging

Swift Build has a few facilities for debugging build problems.

## User Defaults

Currently, you can enable various debugging facilities by setting user defaults.

### Debug activity logs

```
defaults write org.swift.swift-build EnableDebugActivityLogs -bool YES
```

This will cause Swift Build to emit more detailed note diagnostics to the build log
which is deemed to verbose for normal usage.

### Incremental build debugging

```
defaults write org.swift.swift-build EnableBuildBacktraceRecording -bool YES
```

This will cause Swift Build to print build backtraces for each task to the build log. Build backtraces read top to bottom describe how a task was invalidated and the chain of events which triggered that invalidation. For example:
```
Build Backtrace:
an input of 'Create static library libllbuildBuildSystem.a (arm64)' changed
the producer of file '/Users/user/Library/Developer/Xcode/DerivedData/swift-build-cexiveldpggehwhajfsbrdvdsiuf/Build/Intermediates.noindex/InstallIntermediates/macosx/Intermediates.noindex/llbuild.build/Debug/llbuildBuildSystem.build/Objects-normal/arm64/BuildSystemFrontend.o' ran
an input of 'Compile BuildSystemFrontend.cpp (arm64)' changed
file '/Users/user/Development/llbuild/include/llbuild/BuildSystem/BuildSystem.h' changed
```

### Additional tracing for post-mortem analysis

```
defaults write org.swift.swift-build EnableBuildDebugging -bool YES
```

This will cause Swift Build to enable `llbuild`'s tracing feature and also to create
a copy of any existing database, adjacent to the normal database location
(currently `$(OBJROOT)/swift-buildData`).

The database can be inspected using `llbuild`'s UI to see the contents of the
database at the time the build was started. The trace file provides a *very*
low-level description of what the build engine did during the build. The
intention is that eventually llbuild will gain facilities to ingest the pre- and
post- database files and the trace file and provide additional information about
what happened.

## Debugging *llbuild*

If you ever need to inspect the contents of the llbuild database (for example, to see discovered dependencies), the *llbuild* project has a basic web UI which can be used to explore the database.

To do this, check out `llbuild/products/ui/README.md` and follow the instructions to install and start the web viewer, then give it the path (in the web UI) to the database you want to see.

## Multi-process Debugging

The service nature of Swift Build can make debugging painful, when a problem only manifests when Swift Build is running as an inferior service of Xcode.

The recommended way to deal with this is by writing isolated tests that reproduce the problem directly in *SWBBuildService* (without going through IPC). This avoids the need for doing multi-process debugging in the first place, while also increasing our test coverage (and you already have a test case for the bug you want to fix).

If that fails, it is possible to manually attach to the service. Once launched, you can attach to it manually using Xcode or lldb.

If that fails, you can fall back to launch Swift Build in a mode where the service will run entirely in process with the client-side framework (on background queues). This is done by setting `XCBUILD_LAUNCH_IN_PROCESS=1` in the environment.

Xcode also supports using a custom copy of the Swift Build service by overriding `XCBBUILDSERVICE_PATH` in the launched Xcode environment. For example, this can be used to run with a development copy of the service using an installed set of Xcode tools:

    env XCBBUILDSERVICE_PATH=/path/to/SWBBuildService.bundle/Contents/MacOS/SWBBuildService \
        xcodebuild --workspace .../path/to/foo.xcworkspace --scheme All
