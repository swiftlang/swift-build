#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

cmake_minimum_required(VERSION 3.26...3.29)
project(SwiftBuild
  LANGUAGES C CXX Swift)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

set(CMAKE_INSTALL_RPATH "$<IF:$<PLATFORM_ID:Darwin>,@loader_path/..,$ORIGIN>")
set(CMAKE_INSTALL_REMOVE_ENVIRONMENT_RPATH YES)

set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/swift)

option(BUILD_SHARED_LIBS "Build shared libraries by default" YES)

set(CMAKE_C_VISIBILITY hidden)
set(CMAKE_CXX_VISIBILITY hidden)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED YES)
set(CMAKE_CXX_EXTENSIONS NO)
set(CMAKE_VISIBILITY_INLINES_HIDDEN YES)

option(SwiftBuild_USE_LLBUILD_FRAMEWORK "Use LLBuild Framework" NO)

set(SwiftBuild_LANGUAGE_VERSION_6 $<VERSION_LESS:$<TARGET_PROPERTY:Swift_LANGUAGE_VERSION>,6>)
add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:SHELL:-package-name SwiftBuild>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature ConciseMagicFile>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature DeprecateApplicationMain>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature DisableOutwardActorInference>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature ForwardTrailingClosures>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature GlobalConcurrency>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature ImplicitOpenExistentials>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature ImplicitOpenExistentialsImportObjcForwardDeclarations>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature InferSendableFromCaptures>"
                    "$<$<AND:$<COMPILE_LANGUAGE:Swift>,${SwiftBuild_LANGUAGE_VERSION_6}>:SHELL:-enable-upcoming-feature IsolatedDefaultValues>"
                    # rdar://137809703
                    # "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature RegionBasedIsolation>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature ExistentialAny>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature InternalImportsByDefault>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-no-toolchain-stdlib-rpath>"
                    # Turn off autolinking within this project to reduce linker overhead.
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBLibc>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBAndroidPlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBApplePlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBBuildService>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBCLibc>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBGenericUnixPlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBTaskConstruction>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBUtil>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBUniversalPlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBWindowsPlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SwiftBuild>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBWebAssemblyPlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBCSupport>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBMacro>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBProjectModel>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBTaskExecution>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBServiceCore>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBQNXPlatform>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBProtocol>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBLLBuild>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBCore>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBCAS>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBBuildSystem>"
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xfrontend -disable-autolink-library -Xfrontend SWBCore>")

# Prefer the static initialization for the plugins.
add_compile_definitions(USE_STATIC_PLUGIN_INITIALIZATION)

find_package(ArgumentParser)
find_package(LLBuild)
find_package(Subprocess)
find_package(SwiftDriver)
find_package(SwiftSystem)
find_package(TSC)
# NOTE: these two are required for LLBuild dependencies
find_package(Threads)
find_package(SQLite3)

add_subdirectory(Sources)
add_subdirectory(cmake/modules)
