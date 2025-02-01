# Test Development

This document contains various advice related to unit and integration test development in Swift Build.

## Working With PIF Files from Xcode

Sometimes it is useful to have a [PIF](doc:project-interchange-format) to test Swift Build independently of Xcode. To get one, you can run:

    xcrun xcodebuild -dumpPIF path/to/output.pif -project path/to/project.xcodeproj

## Saving Temporary Directories

Many of our tests create temporary directories on the file system and automatically destroy them when complete. If you would like to not have these destroyed (so you can inspect them), you can run with `SAVE_TEMPS=1` set in the environment.

## Writing Project Tests

Project tests are a kind of integration test used to test build system functionality, and one of the most important classes of test in Swift Build.

<doc:test-development-project-tests>
