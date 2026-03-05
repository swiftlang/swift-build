# Windows Platform

In most cases, the clang and swift compilers will automatically detect the requisite components installed on the system by searching the environment and/or registry. However, Swift Build contains its own lookup logic and explicitly passes paths and versions of dependencies to the compiler in order to have more direct control over the build process and version selection.

## System Requirements

There are a number of components required for building for Windows...

### Visual C++

The most basic requirement is the Visual C++ compiler and runtime. To get this, you must install any edition of Visual Studio (Build Tools, Community, Professional, Enterprise). The Visual Studio installer also places a tool called vswhere at the fixed location of `%PROGRAMFILES(X86)%\Microsoft Visual Studio\Installer\vswhere.exe`, which Swift Build uses to look up the Visual Studio installations on the system, and their properties.

### Windows SDK

The Windows SDK is also required for accessing the Windows API, and can also be installed via the Visual Studio installer.

## Lookup Process

First the compiler must find the Visual C++ toolchain via a combination of environment variables and/or command line flags. Note that this documentation is only concerned with the "modern" toolchain layout in Visual Studio 2017 and later versions.

The following table is a state machine for clang's search path logic for the VC tools install dir. The environment variable fallback will also search the PATH, and then ISetupConfig, and then the registry, details of which are not covered here. See https://github.com/swiftlang/llvm-project/blob/next/clang/docs/UsersManual.rst#windows-system-headers-and-library-lookup for more.

| -Xmicrosoft-windows-sys-root | -Xmicrosoft-visualc-tools-version | -Xmicrosoft-visualc-tools-root | Value                                                      |
| ---------------------------- | --------------------------------- | ------------------------------ | ---------------------------------------------------------- |
| Yes                          | Yes                               | -                              | `%windows-sys-root%\VC\Tools\MSVC\%visualc-tools-version%` |
| Yes                          | No                                | -                              | `%windows-sys-root%\VC\Tools\MSVC\<latest>`                |
| No                           | -                                 | Yes                            | `%visualc-tools-root%`                                     |
| No                           | -                                 | No                             | environment variable `VCToolsInstallDir`                   |

### Examples

Example values that can be given to various Swift compiler options:

| Flag                   | Example value                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| -sdk                   | `%LOCALAPPDATA%\Programs\Swift\Platforms\6.1.0\Windows.platform\Developer\SDKs\Windows.sdk` |
| -windows-sdk-root      | `%PROGRAMFILES(X86)%\Windows Kits\10\10.0.26100.0`                                          |
| -windows-sdk-version   | `10.0.26100.0`                                                                              |
| -visualc-tools-root    | `%PROGRAMFILES%\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207`           |
| -visualc-tools-version | `14.44.35207`                                                                               |

Example values that can be given to various clang compiler options:

| Flag                              | Example value                                                                     |
| --------------------------------- | --------------------------------------------------------------------------------- |
| -Xmicrosoft-windows-sdk-root      | `%PROGRAMFILES(X86)%\Windows Kits\10\10.0.26100.0`                                |
| -Xmicrosoft-windows-sdk-version   | `10.0.26100.0`                                                                    |
| -Xmicrosoft-visualc-tools-root    | `%PROGRAMFILES%\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207` |
| -Xmicrosoft-visualc-tools-version | `14.44.35207`                                                                     |
| -Xmicrosoft-windows-sys-root      | `%PROGRAMFILES%\Microsoft Visual Studio\2022\Community`                           |

Example values for relevant environment variables:

| Environment variable | Example value                                                                       |
| -------------------- | ----------------------------------------------------------------------------------- |
| VCToolsInstallDir    | `C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207` |
