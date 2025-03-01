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
                    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-upcoming-feature InternalImportsByDefault>")

# Prefer the static initialization for the plugins.
add_compile_definitions(USE_STATIC_PLUGIN_INITIALIZATION)

find_package(ArgumentParser)
find_package(LLBuild)
find_package(SwiftDriver)
find_package(SwiftSystem)
find_package(TSC)
# NOTE: these two are required for LLBuild dependencies
find_package(Threads)
find_package(SQLite3)

add_subdirectory(Sources)
