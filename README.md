Swift Build
=======

Swift Build is a high-level build system based on [llbuild](https://github.com/swiftlang/swift-llbuild) with great support for building Swift. It is used by Xcode to build Xcode projects and Swift packages, and by Swift Playground. It can also be used as the Swift Package Manager build system in preview form when passing `--build-system swiftbuild`.

Usage
-----

### With SwiftPM

When building SwiftPM from sources which include Swift Build integration, passing `--build-system swiftbuild` will enable the new build-system. This functionality is not currently available in nightly toolchains.

### With Xcode

Changes to swift-build can also be tested in Xcode using the `launch-xcode` command plugin provided by the package. Run `swift package --disable-sandbox launch-xcode` from your checkout of swift-build to launch a copy of the currently `xcode-select`ed Xcode.app configured to use your modified copy of the build system service. This workflow is currently supported when using Xcode 16.2.

### With xcodebuild

Changes to swift-build can also be tested in xcodebuild using the `run-xcodebuild` command plugin provided by the package. Run `swift package --disable-sandbox run-xcodebuild` from your checkout of swift-build to run xcodebuild from the currently `xcode-select`ed Xcode.app configured to use your modified copy of the build system service. Arguments followed by `--` will be forwarded to xcodebuild unmodified. This workflow is currently supported when using Xcode 16.2.

### Debugging

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
