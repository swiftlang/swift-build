Swift Build
=======

Swift Build is a build engine based on [llbuild](https://github.com/swiftlang/swift-llbuild) with great support for building Swift. It is used by Xcode to build Xcode projects and Swift packages. It can also be used as the Swift Package Manager build system in preview form when passing `--build-system swift-build`.

Usage
-----

### With SwiftPM

When building SwiftPM from sources which include Swift Build integration, passing `--build-system swift-build` will enable the new build-system. This functionality is not currently available in nightly toolchains.

### With Xcode

Changes to swift-build can also be tested in Xcode using the `launch-xcode` command plugin provided by the package. Run `swift package launch-xcode --disable-sandbox` from your checkout of swift-build to launch a copy of the currently `xcode-select`ed Xcode.app configured to use your modified copy of the build system service. This workflow is currently supported when using Xcode 16.2.

Documentation
-------------

[SwiftBuild.docc](SwiftBuild.docc) contains additional technical documentation.

Contributing to Swift Build
------------

Contributions to Swift Build are welcomed and encouraged! Please see the
[Contributing to Swift guide](https://swift.org/contributing/).

Before submitting the pull request, please make sure you have [tested your
 changes](https://github.com/apple/swift/blob/main/docs/ContinuousIntegration.md)
 and that they follow the Swift project [guidelines for contributing
 code](https://swift.org/contributing/#contributing-code). Bug reports should be 
 filed in [the issue tracker](https://github.com/apple/swift-build/issues) of 
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
