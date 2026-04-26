Swift Build
=======

Swift Build is a high-level build system based on [llbuild](https://github.com/swiftlang/swift-llbuild) with great support for building Swift. It is used by SwiftPM, Xcode, and Swift Playground.

Usage
-----

### With SwiftPM

Swift Build is the default SwiftPM build system in nightly snapshots of Swift's `main` branches. In Swift 6.2 and 6.3, it can be enabled by passing `--build-system swiftbuild`. When building SwiftPM from source it will be built as a package dependency. When checking out the full set of Swift repositories, `SWIFTCI_USE_LOCAL_DEPS=1 swift build --package-path /path/to/swiftpm` can be used to test local changes to Swift Build and SwiftPM together. The `Utilities` directory also contains `SwiftPM+SwiftBuild.xcworkspace` which allows codeveloping the two repositories in Xcode on macOS.

### With Xcode

Changes to swift-build can also be tested in Xcode using the `launch-xcode` command plugin provided by the package. Run `swift package --disable-sandbox launch-xcode` from your checkout of swift-build to launch a copy of the currently `xcode-select`ed Xcode.app configured to use your modified copy of the build system service. This workflow is generally only supported when using the latest available Xcode version.

### With xcodebuild

Changes to swift-build can also be tested in xcodebuild using the `run-xcodebuild` command plugin provided by the package. Run `swift package --disable-sandbox run-xcodebuild` from your checkout of swift-build to run xcodebuild from the currently `xcode-select`ed Xcode.app configured to use your modified copy of the build system service. Arguments followed by `--` will be forwarded to xcodebuild unmodified. This workflow is generally only supported when using the latest available Xcode version.

### Debugging

When using Swift Build with SwiftPM, the build process runs entirely within the `swift-build` (or `swift-test`, `swift-run`, etc.) process. You can debug by using `swift run --debugger swift-build ...` or an IDE like VSCode or Xcode.

When using the Xcode or xcodebuild workflows above, you can easily set breakpoints and debug. First, open the swift-build package containing your changes in Xcode and choose the "Debug > Attach to Process by PID or Name…" menu item. In the panel that appears, type "SWBBuildServiceBundle" as the process name and click "Attach". The debugger will wait for the process to launch. Run the relevant command shown above to launch Xcode or xcodebuild, and once you open a workspace the swift-build process will launch and the debugger will attach to it automatically.

Documentation
-------------

[SwiftBuild.docc](SwiftBuild.docc) contains additional technical documentation.

To view the documentation in browser, run the following command at the root of the project:
```bash
docc preview SwiftBuild.docc
```

On macOS, use:
```bash
xcrun docc preview SwiftBuild.docc
```

Testing
-------------
Before submitting the pull request, please make sure you have tested your changes. You can run the full test suite by running `swift test` from the root of the repository. The test suite is organized into a number of different test targets, with each corresponding to a specific component. For example, `SWBTaskConstructionTests` contains tests for the `SWBTaskConstruction` module which plan builds and then inspect the resulting build graph. Many tests in Swift Build operate on test project model objects which emulate those constructed by a higher level client and validate behavior at different layers. You can learn more about how these tests are written and organized in [Project Tests](SwiftBuild.docc/Development/test-development-project-tests.md).


Contributing to Swift Build
------------

Contributions to Swift Build are welcomed and encouraged! Please see the
[Contributing to Swift guide](https://swift.org/contributing/).

Before submitting the pull request, please make sure that they follow the Swift project [guidelines for contributing
 code](https://swift.org/contributing/#contributing-code). Bug reports should be
 filed in [the issue tracker](https://github.com/swiftlang/swift-build/issues) of
 `swift-build` repository on GitHub.

To be a truly great community, [Swift.org](https://swift.org/) needs to welcome
developers from all walks of life, with different backgrounds, and with a wide
range of experience. A diverse and friendly community will have more great
ideas, more unique perspectives, and produce more great code. We will work
diligently to make the Swift community welcoming to everyone.

To give clarity of what is expected of our members, Swift has adopted the
code of conduct defined by the Contributor Covenant. This document is used
across many open source communities, and we think it articulates our values
well. For more, see the [Code of Conduct](https://swift.org/code-of-conduct/).

License
-------
See https://swift.org/LICENSE.txt for license information.
