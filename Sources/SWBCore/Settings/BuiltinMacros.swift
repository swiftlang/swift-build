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

public import SWBMacro
import Synchronization

/// The builtin macro declarations for things which are used directly by the build system.
public final class BuiltinMacros {

    // MARK: Built-in Macro Conditions

    public static let archCondition = BuiltinMacros.declareConditionParameter("arch")
    public static let compilerCondition = BuiltinMacros.declareConditionParameter("compiler")
    public static let sdkCondition = BuiltinMacros.declareConditionParameter("sdk")
    public static let variantCondition = BuiltinMacros.declareConditionParameter("variant")
    public static let configurationCondition = BuiltinMacros.declareConditionParameter("config")
    public static let platformCondition = BuiltinMacros.declareConditionParameter("__platform_filter")
    public static let sdkBuildVersionCondition = BuiltinMacros.declareConditionParameter("_sdk_build_version")

    private static let allBuiltinConditionParameters = [archCondition, compilerCondition, sdkCondition, variantCondition, configurationCondition, platformCondition, sdkBuildVersionCondition]

    // MARK: Built-in Macro Definitions

    /// The name of the active architecture (in appropriate contexts).
    public static let arch = BuiltinMacros.declareStringMacro("arch")
    /// The name of the active variant (in appropriate contexts).
    public static let variant = BuiltinMacros.declareStringMacro("variant")
    /// Special macro used in generic command line evaluation, to refer to the triggering value.
    public static let value = BuiltinMacros.declareStringMacro("value")

    /// The internal setting capturing the per-file flags to pass to a tool for a specific file.
    public static let build_file_compiler_flags = BuiltinMacros.declareStringListMacro("build_file_compiler_flags")

    // This only used by tiffutil, consider eliminating.
    public static let OutputFileBase = BuiltinMacros.declareStringMacro("OutputFileBase")

    // This is only used by the product packaging utility when processing entitlements.
    public static let AppIdentifierPrefix = BuiltinMacros.declareStringMacro("AppIdentifierPrefix")
    public static let CodeSignEntitlements = BuiltinMacros.declareBooleanMacro("CodeSignEntitlements")
    public static let TeamIdentifierPrefix = BuiltinMacros.declareStringMacro("TeamIdentifierPrefix")

    public static let OutputFormat = BuiltinMacros.declareStringMacro("OutputFormat")
    public static let OutputPath = BuiltinMacros.declareStringMacro("OutputPath")
    // Builtin tool specs use this instead of OutputPath.
    // FIXME: Consolidate OutputPath and OutputFile into a single macro ( rdar://57299916 ).
    public static let OutputFile = BuiltinMacros.declareStringMacro("OutputFile")
    public static let OutputRelativePath = BuiltinMacros.declareStringMacro("OutputRelativePath")

    public static let PROJECT_CLASS_PREFIX = BuiltinMacros.declareStringMacro("PROJECT_CLASS_PREFIX")

    /// The name of the active configuration.
    public static let CONFIGURATION = BuiltinMacros.declareStringMacro("CONFIGURATION")

    /// The list of enabled toolchains.
    public static let TOOLCHAINS = BuiltinMacros.declareStringListMacro("TOOLCHAINS")
    public static let EFFECTIVE_TOOLCHAINS_DIRS = BuiltinMacros.declareStringListMacro("EFFECTIVE_TOOLCHAINS_DIRS")
    public static let TOOLCHAIN_DIR = BuiltinMacros.declarePathMacro("TOOLCHAIN_DIR")

    public static let __108704016_DEVELOPER_TOOLCHAIN_DIR_MISUSE_IS_WARNING = BuiltinMacros.declareBooleanMacro("__108704016_DEVELOPER_TOOLCHAIN_DIR_MISUSE_IS_WARNING")

    // MARK: The various root path directories.

    public static let CCHROOT = BuiltinMacros.declarePathMacro("CCHROOT")
    public static let DSTROOT = BuiltinMacros.declarePathMacro("DSTROOT")
    public static let LOCROOT = BuiltinMacros.declarePathMacro("LOCROOT")
    public static let LOCSYMROOT = BuiltinMacros.declarePathMacro("LOCSYMROOT")
    public static let OBJROOT = BuiltinMacros.declarePathMacro("OBJROOT")
    public static let SRCROOT = BuiltinMacros.declarePathMacro("SRCROOT")
    public static let SOURCE_ROOT = BuiltinMacros.declarePathMacro("SOURCE_ROOT")
    public static let SYMROOT = BuiltinMacros.declarePathMacro("SYMROOT")

    public static let DERIVED_DATA_DIR = BuiltinMacros.declarePathMacro("DERIVED_DATA_DIR")
    public static let INDEX_DATA_STORE_DIR = BuiltinMacros.declarePathMacro("INDEX_DATA_STORE_DIR")
    public static let INDEX_ENABLE_DATA_STORE = BuiltinMacros.declareBooleanMacro("INDEX_ENABLE_DATA_STORE")
    public static let INDEX_PRECOMPS_DIR = BuiltinMacros.declarePathMacro("INDEX_PRECOMPS_DIR")
    public static let MODULE_CACHE_DIR = BuiltinMacros.declarePathMacro("MODULE_CACHE_DIR")
    public static let SHARED_PRECOMPS_DIR = BuiltinMacros.declarePathMacro("SHARED_PRECOMPS_DIR")
    public static let TEMP_SANDBOX_DIR = BuiltinMacros.declarePathMacro("TEMP_SANDBOX_DIR")

    // This is a setting to provide a workaround for rdar://52005109. It shouldn't be used or promoted!
    public static let BUILD_DESCRIPTION_CACHE_DIR = BuiltinMacros.declareStringMacro("BUILD_DESCRIPTION_CACHE_DIR")

    // MAKR: Version properties.

    public static let MAC_OS_X_VERSION_ACTUAL = BuiltinMacros.declareStringMacro("MAC_OS_X_VERSION_ACTUAL")
    public static let MAC_OS_X_VERSION_MAJOR = BuiltinMacros.declareStringMacro("MAC_OS_X_VERSION_MAJOR")
    public static let MAC_OS_X_VERSION_MINOR = BuiltinMacros.declareStringMacro("MAC_OS_X_VERSION_MINOR")
    public static let MAC_OS_X_PRODUCT_BUILD_VERSION = BuiltinMacros.declareStringMacro("MAC_OS_X_PRODUCT_BUILD_VERSION")

    public static let XCODE_VERSION_ACTUAL = BuiltinMacros.declareStringMacro("XCODE_VERSION_ACTUAL")
    public static let XCODE_VERSION_MAJOR = BuiltinMacros.declareStringMacro("XCODE_VERSION_MAJOR")
    public static let XCODE_VERSION_MINOR = BuiltinMacros.declareStringMacro("XCODE_VERSION_MINOR")
    public static let XCODE_PRODUCT_BUILD_VERSION = BuiltinMacros.declareStringMacro("XCODE_PRODUCT_BUILD_VERSION")

    // MARK: Platform properties.

    public static let CORRESPONDING_DEVICE_PLATFORM_DIR = BuiltinMacros.declareStringMacro("CORRESPONDING_DEVICE_PLATFORM_DIR")
    public static let CORRESPONDING_DEVICE_PLATFORM_NAME = BuiltinMacros.declareStringMacro("CORRESPONDING_DEVICE_PLATFORM_NAME")
    public static let CORRESPONDING_SIMULATOR_PLATFORM_DIR = BuiltinMacros.declareStringMacro("CORRESPONDING_SIMULATOR_PLATFORM_DIR")
    public static let CORRESPONDING_SIMULATOR_PLATFORM_NAME = BuiltinMacros.declareStringMacro("CORRESPONDING_SIMULATOR_PLATFORM_NAME")
    public static let CORRESPONDING_DEVICE_SDK_DIR = BuiltinMacros.declareStringMacro("CORRESPONDING_DEVICE_SDK_DIR")
    public static let CORRESPONDING_DEVICE_SDK_NAME = BuiltinMacros.declareStringMacro("CORRESPONDING_DEVICE_SDK_NAME")
    public static let CORRESPONDING_SIMULATOR_SDK_DIR = BuiltinMacros.declareStringMacro("CORRESPONDING_SIMULATOR_SDK_DIR")
    public static let CORRESPONDING_SIMULATOR_SDK_NAME = BuiltinMacros.declareStringMacro("CORRESPONDING_SIMULATOR_SDK_NAME")
    public static let DEPLOYMENT_TARGET_SETTING_NAME = BuiltinMacros.declareStringMacro("DEPLOYMENT_TARGET_SETTING_NAME")
    public static let EFFECTIVE_PLATFORM_NAME = BuiltinMacros.declareStringMacro("EFFECTIVE_PLATFORM_NAME")
    public static let EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR = BuiltinMacros.declareBooleanMacro("EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR")
    public static let EFFECTIVE_PLATFORM_SUFFIX = BuiltinMacros.declareStringMacro("EFFECTIVE_PLATFORM_SUFFIX")
    public static let EXCLUDED_ARCHS = BuiltinMacros.declareStringListMacro("EXCLUDED_ARCHS")
    public static let HOST_PLATFORM = BuiltinMacros.declareStringMacro("HOST_PLATFORM")
    public static let IOS_UNZIPPERED_TWIN_PREFIX_PATH = BuiltinMacros.declareStringMacro("IOS_UNZIPPERED_TWIN_PREFIX_PATH")
    public static let IPHONEOS_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("IPHONEOS_DEPLOYMENT_TARGET")
    public static let MACOSX_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("MACOSX_DEPLOYMENT_TARGET")
    public static let NATIVE_ARCH = BuiltinMacros.declareStringMacro("NATIVE_ARCH")
    public static let NATIVE_ARCH_32_BIT = BuiltinMacros.declareStringMacro("NATIVE_ARCH_32_BIT")
    public static let NATIVE_ARCH_64_BIT = BuiltinMacros.declareStringMacro("NATIVE_ARCH_64_BIT")
    public static let NATIVE_ARCH_ACTUAL = BuiltinMacros.declareStringMacro("NATIVE_ARCH_ACTUAL")
    public static let PLATFORM_DEVELOPER_APPLICATIONS_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DEVELOPER_APPLICATIONS_DIR")
    public static let PLATFORM_DEVELOPER_BIN_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DEVELOPER_BIN_DIR")
    public static let PLATFORM_DEVELOPER_LIBRARY_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DEVELOPER_LIBRARY_DIR")
    public static let PLATFORM_DEVELOPER_SDK_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DEVELOPER_SDK_DIR")
    public static let PLATFORM_DEVELOPER_TOOLS_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DEVELOPER_TOOLS_DIR")
    public static let PLATFORM_DEVELOPER_USR_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DEVELOPER_USR_DIR")
    public static let PLATFORM_DIR = BuiltinMacros.declareStringMacro("PLATFORM_DIR")
    public static let PLATFORM_DISPLAY_NAME = BuiltinMacros.declareStringMacro("PLATFORM_DISPLAY_NAME")
    public static let PLATFORM_FAMILY_NAME = BuiltinMacros.declareStringMacro("PLATFORM_FAMILY_NAME")
    public static let PLATFORM_NAME = BuiltinMacros.declareStringMacro("PLATFORM_NAME")
    public static let __USE_PLATFORM_NAME_FOR_FILTERS = BuiltinMacros.declareBooleanMacro("__USE_PLATFORM_NAME_FOR_FILTERS")
    public static let PLATFORM_PREFERRED_ARCH = BuiltinMacros.declareStringMacro("PLATFORM_PREFERRED_ARCH")
    public static let PLATFORM_PRODUCT_BUILD_VERSION = BuiltinMacros.declareStringMacro("PLATFORM_PRODUCT_BUILD_VERSION")
    public static let SUPPORTED_PLATFORMS = BuiltinMacros.declareStringListMacro("SUPPORTED_PLATFORMS")
    public static let SUPPORTED_HOST_TARGETED_PLATFORMS = BuiltinMacros.declareStringListMacro("SUPPORTED_HOST_TARGETED_PLATFORMS")
    public static let HOST_TARGETED_PLATFORM_NAME = BuiltinMacros.declareStringMacro("HOST_TARGETED_PLATFORM_NAME")
    public static let SUPPORTS_MACCATALYST = BuiltinMacros.declareBooleanMacro("SUPPORTS_MACCATALYST")
    public static let SUPPORTS_ON_DEMAND_RESOURCES = BuiltinMacros.declareBooleanMacro("SUPPORTS_ON_DEMAND_RESOURCES")
    public static let SWIFT_PLATFORM_TARGET_PREFIX = BuiltinMacros.declareStringMacro("SWIFT_PLATFORM_TARGET_PREFIX")
    public static let TVOS_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("TVOS_DEPLOYMENT_TARGET")
    public static let VALID_ARCHS = BuiltinMacros.declareStringListMacro("VALID_ARCHS")
    public static let WATCHOS_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("WATCHOS_DEPLOYMENT_TARGET")

    // MARK: Swift module-only properties.

    public static let SWIFT_MODULE_ONLY_ARCHS = BuiltinMacros.declareStringListMacro("SWIFT_MODULE_ONLY_ARCHS")
    public static let __SWIFT_MODULE_ONLY_ARCHS__ = BuiltinMacros.declareStringListMacro("__SWIFT_MODULE_ONLY_ARCHS__")

    public static let SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET")
    public static let SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET")
    public static let SWIFT_MODULE_ONLY_TVOS_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("SWIFT_MODULE_ONLY_TVOS_DEPLOYMENT_TARGET")
    public static let SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET")

    // MARK: SDK properties.

    public static let ADDITIONAL_SDKS = BuiltinMacros.declareStringListMacro("ADDITIONAL_SDKS")
    public static let ADDITIONAL_SDK_DIRS = BuiltinMacros.declareStringListMacro("ADDITIONAL_SDK_DIRS")
    public static let SDKROOT = BuiltinMacros.declarePathMacro("SDKROOT")
    public static let SDK_DIR = BuiltinMacros.declareStringMacro("SDK_DIR")
    public static let SDK_NAME = BuiltinMacros.declareStringMacro("SDK_NAME")
    public static let SDK_NAMES = BuiltinMacros.declareStringListMacro("SDK_NAMES")
    public static let SDK_PRODUCT_BUILD_VERSION = BuiltinMacros.declareStringMacro("SDK_PRODUCT_BUILD_VERSION")
    public static let SDK_VARIANT = BuiltinMacros.declareStringMacro("SDK_VARIANT")
    public static let SDK_VERSION = BuiltinMacros.declareStringMacro("SDK_VERSION")
    public static let SDK_VERSION_ACTUAL = BuiltinMacros.declareStringMacro("SDK_VERSION_ACTUAL")
    public static let SDK_VERSION_MAJOR = BuiltinMacros.declareStringMacro("SDK_VERSION_MAJOR")
    public static let SDK_VERSION_MINOR = BuiltinMacros.declareStringMacro("SDK_VERSION_MINOR")
    public static let SDK_STAT_CACHE_PATH = BuiltinMacros.declareStringMacro("SDK_STAT_CACHE_PATH")
    public static let SDK_STAT_CACHE_DIR = BuiltinMacros.declareStringMacro("SDK_STAT_CACHE_DIR")
    public static let SDK_STAT_CACHE_ENABLE = BuiltinMacros.declareBooleanMacro("SDK_STAT_CACHE_ENABLE")
    public static let SDK_STAT_CACHE_VERBOSE_LOGGING = BuiltinMacros.declareBooleanMacro("SDK_STAT_CACHE_VERBOSE_LOGGING")
    public static let SPECIALIZATION_SDK_OPTIONS = BuiltinMacros.declareStringListMacro("SPECIALIZATION_SDK_OPTIONS")

    public static let DEPLOYMENT_TARGET_SUGGESTED_VALUES = BuiltinMacros.declareStringListMacro("DEPLOYMENT_TARGET_SUGGESTED_VALUES")
    public static let GCC_THUMB_SUPPORT = BuiltinMacros.declareBooleanMacro("GCC_THUMB_SUPPORT")
    public static let KASAN_DEFAULT_CFLAGS = BuiltinMacros.declareStringListMacro("KASAN_DEFAULT_CFLAGS")
    public static let SUPPORTED_DEVICE_FAMILIES = BuiltinMacros.declareStringListMacro("SUPPORTED_DEVICE_FAMILIES")
    public static let OBJC_ABI_VERSION = BuiltinMacros.declareStringMacro("OBJC_ABI_VERSION")

    // MARK: Project properties.

    public static let DEVELOPMENT_LANGUAGE = BuiltinMacros.declareStringMacro("DEVELOPMENT_LANGUAGE")
    /// The name of the project.
    public static let PROJECT_NAME = BuiltinMacros.declareStringMacro("PROJECT_NAME")
    public static let PROJECT_GUID = BuiltinMacros.declareStringMacro("PROJECT_GUID")
    public static let PROJECT_FILE_PATH = BuiltinMacros.declareStringMacro("PROJECT_FILE_PATH")
    public static let PROJECT_DIR = BuiltinMacros.declarePathMacro("PROJECT_DIR")
    public static let PROJECT_TEMP_DIR = BuiltinMacros.declarePathMacro("PROJECT_TEMP_DIR")
    public static let WORKSPACE_DIR = BuiltinMacros.declareStringMacro("WORKSPACE_DIR")

    // These aren't really project properties, but it is where they are current set.
    public static let HOME = BuiltinMacros.declarePathMacro("HOME")
    public static let USER = BuiltinMacros.declareStringMacro("USER")
    public static let GROUP = BuiltinMacros.declareStringMacro("GROUP")
    public static let UID = BuiltinMacros.declareStringMacro("UID")
    public static let GID = BuiltinMacros.declareStringMacro("GID")

    // FIXME: These should be deprecated.
    public static let BUILD_STYLE = BuiltinMacros.declareStringMacro("BUILD_STYLE")
    public static let PROJECT = BuiltinMacros.declareStringMacro("PROJECT")
    public static let TEMP_DIR = BuiltinMacros.declarePathMacro("TEMP_DIR")

    // MARK: Target properties.

    public static let BUILT_PRODUCTS_DIR = BuiltinMacros.declarePathMacro("BUILT_PRODUCTS_DIR")
    public static let CONFIGURATION_BUILD_DIR = BuiltinMacros.declarePathMacro("CONFIGURATION_BUILD_DIR")
    public static let CONFIGURATION_TEMP_DIR = BuiltinMacros.declarePathMacro("CONFIGURATION_TEMP_DIR")
    public static let PACKAGE_TYPE = BuiltinMacros.declareStringMacro("PACKAGE_TYPE")
    public static let PRODUCT_NAME = BuiltinMacros.declareStringMacro("PRODUCT_NAME")
    public static let PRODUCT_TYPE = BuiltinMacros.declareStringMacro("PRODUCT_TYPE")
    public static let TARGET_BUILD_DIR = BuiltinMacros.declarePathMacro("TARGET_BUILD_DIR")
    public static let TARGET_BUILD_SUBPATH = BuiltinMacros.declarePathMacro("TARGET_BUILD_SUBPATH")
    public static let TARGET_NAME = BuiltinMacros.declareStringMacro("TARGET_NAME")
    public static let TARGET_TEMP_DIR = BuiltinMacros.declarePathMacro("TARGET_TEMP_DIR")
    // FIXME: This macro should be deprecated.
    public static let TARGETNAME = BuiltinMacros.declareStringMacro("TARGETNAME")

    // MARK: Target overrides.

    public static let ACTION = BuiltinMacros.declareStringMacro("ACTION")
    public static let ARCHS = BuiltinMacros.declareStringListMacro("ARCHS")
    public static let BUILD_COMPONENTS = BuiltinMacros.declareStringListMacro("BUILD_COMPONENTS")
    public static let DEPLOYMENT_LOCATION = BuiltinMacros.declareBooleanMacro("DEPLOYMENT_LOCATION")
    public static let DEPLOYMENT_POSTPROCESSING = BuiltinMacros.declareBooleanMacro("DEPLOYMENT_POSTPROCESSING")
    public static let ENABLE_TESTABILITY = BuiltinMacros.declareBooleanMacro("ENABLE_TESTABILITY")
    public static let ENABLE_TESTING_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_TESTING_SEARCH_PATHS")
    public static let ENABLE_PRIVATE_TESTING_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_PRIVATE_TESTING_SEARCH_PATHS")
    public static let EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING = BuiltinMacros.declareBooleanMacro("EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING")
    public static let GCC_SYMBOLS_PRIVATE_EXTERN = BuiltinMacros.declareBooleanMacro("GCC_SYMBOLS_PRIVATE_EXTERN")
    public static let IMPLICIT_DEPENDENCIES_IGNORE_LDFLAGS = BuiltinMacros.declareBooleanMacro("IMPLICIT_DEPENDENCIES_IGNORE_LDFLAGS")
    public static let INSTALLAPI_COPY_PHASE = BuiltinMacros.declareBooleanMacro("INSTALLAPI_COPY_PHASE")
    public static let INSTALLAPI_IGNORE_SKIP_INSTALL = BuiltinMacros.declareBooleanMacro("INSTALLAPI_IGNORE_SKIP_INSTALL")
    public static let INSTALLAPI_MODE_ENABLED = BuiltinMacros.declareBooleanMacro("INSTALLAPI_MODE_ENABLED")
    public static let INSTALLED_PRODUCT_ASIDES = BuiltinMacros.declareBooleanMacro("INSTALLED_PRODUCT_ASIDES")
    public static let INSTALL_PATH = BuiltinMacros.declarePathMacro("INSTALL_PATH")
    public static let INSTALL_ROOT = BuiltinMacros.declarePathMacro("INSTALL_ROOT")
    public static let LLVM_LTO = BuiltinMacros.declareStringMacro("LLVM_LTO")
    public static let RETAIN_RAW_BINARIES = BuiltinMacros.declareBooleanMacro("RETAIN_RAW_BINARIES")
    public static let SEPARATE_SYMBOL_EDIT = BuiltinMacros.declareBooleanMacro("SEPARATE_SYMBOL_EDIT")
    public static let SKIP_INSTALL = BuiltinMacros.declareBooleanMacro("SKIP_INSTALL")
    public static let SKIP_CLANG_STATIC_ANALYZER = BuiltinMacros.declareBooleanMacro("SKIP_CLANG_STATIC_ANALYZER")
    public static let SKIP_EMBEDDED_FRAMEWORKS_VALIDATION = BuiltinMacros.declareBooleanMacro("SKIP_EMBEDDED_FRAMEWORKS_VALIDATION")
    public static let STRINGSDATA_DIR = BuiltinMacros.declarePathMacro("STRINGSDATA_DIR")
    public static let STRIP_BITCODE_FROM_COPIED_FILES = BuiltinMacros.declareBooleanMacro("STRIP_BITCODE_FROM_COPIED_FILES")
    public static let STRIP_INSTALLED_PRODUCT = BuiltinMacros.declareBooleanMacro("STRIP_INSTALLED_PRODUCT")
    public static let STRIP_PNG_TEXT = BuiltinMacros.declareBooleanMacro("STRIP_PNG_TEXT")
    public static let STRIP_STYLE = BuiltinMacros.declareEnumMacro("STRIP_STYLE") as EnumMacroDeclaration<StripStyle>
    public static let STRIP_SWIFT_SYMBOLS = BuiltinMacros.declareBooleanMacro("STRIP_SWIFT_SYMBOLS")
    public static let STRIPFLAGS = BuiltinMacros.declareStringListMacro("STRIPFLAGS")
    public static let UNSTRIPPED_PRODUCT = BuiltinMacros.declareBooleanMacro("UNSTRIPPED_PRODUCT")

    // MARK: Various macros which are usually set to static literal values.

    // FIXME: This macro should be deprecated.
    public static let OS = BuiltinMacros.declareStringMacro("OS")

    public static let CACHE_ROOT = BuiltinMacros.declarePathMacro("CACHE_ROOT")

    public static let LOCAL_ADMIN_APPS_DIR = BuiltinMacros.declareStringMacro("LOCAL_ADMIN_APPS_DIR")
    public static let LOCAL_APPS_DIR = BuiltinMacros.declareStringMacro("LOCAL_APPS_DIR")
    public static let LOCAL_DEVELOPER_DIR = BuiltinMacros.declareStringMacro("LOCAL_DEVELOPER_DIR")
    public static let LOCAL_DEVELOPER_EXECUTABLES_DIR = BuiltinMacros.declareStringMacro("LOCAL_DEVELOPER_EXECUTABLES_DIR")
    public static let LOCAL_LIBRARY_DIR = BuiltinMacros.declareStringMacro("LOCAL_LIBRARY_DIR")
    public static let SYSTEM_APPS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_APPS_DIR")
    public static let SYSTEM_ADMIN_APPS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_ADMIN_APPS_DIR")
    public static let SYSTEM_DEMOS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEMOS_DIR")
    public static let SYSTEM_LIBRARY_DIR = BuiltinMacros.declareStringMacro("SYSTEM_LIBRARY_DIR")
    public static let SYSTEM_CORE_SERVICES_DIR = BuiltinMacros.declareStringMacro("SYSTEM_CORE_SERVICES_DIR")
    public static let SYSTEM_DOCUMENTATION_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DOCUMENTATION_DIR")
    public static let SYSTEM_LIBRARY_EXECUTABLES_DIR = BuiltinMacros.declareStringMacro("SYSTEM_LIBRARY_EXECUTABLES_DIR")
    public static let SYSTEM_DEVELOPER_EXECUTABLES_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_EXECUTABLES_DIR")
    public static let SYSTEM_PREFIX = BuiltinMacros.declareStringMacro("SYSTEM_PREFIX")
    public static let TREAT_MISSING_SCRIPT_PHASE_OUTPUTS_AS_ERRORS = BuiltinMacros.declareBooleanMacro("TREAT_MISSING_SCRIPT_PHASE_OUTPUTS_AS_ERRORS")
    public static let USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES = BuiltinMacros.declareBooleanMacro("USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES")
    public static let USER_APPS_DIR = BuiltinMacros.declareStringMacro("USER_APPS_DIR")
    public static let USER_LIBRARY_DIR = BuiltinMacros.declareStringMacro("USER_LIBRARY_DIR")

    // MARK: The computed path macros.
    //
    // FIXME: We should see which of these can be deprecated.

    public static let SYSTEM_DEVELOPER_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_DIR")
    public static let DEVELOPER_DIR = BuiltinMacros.declarePathMacro("DEVELOPER_DIR")
    public static let LEGACY_DEVELOPER_DIR = BuiltinMacros.declarePathMacro("LEGACY_DEVELOPER_DIR")
    public static let SYSTEM_DEVELOPER_APPS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_APPS_DIR")
    public static let DEVELOPER_APPLICATIONS_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_APPLICATIONS_DIR")
    public static let DEVELOPER_LIBRARY_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_LIBRARY_DIR")
    public static let DEVELOPER_FRAMEWORKS_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_FRAMEWORKS_DIR")
    // FIXME: Deprecate this.
    public static let DEVELOPER_FRAMEWORKS_DIR_QUOTED = BuiltinMacros.declareStringMacro("DEVELOPER_FRAMEWORKS_DIR_QUOTED")
    // FIXME: Deprecate this.
    public static let SYSTEM_DEVELOPER_JAVA_TOOLS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_JAVA_TOOLS_DIR")
    public static let SYSTEM_DEVELOPER_PERFORMANCE_TOOLS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_PERFORMANCE_TOOLS_DIR")
    public static let SYSTEM_DEVELOPER_GRAPHICS_TOOLS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_GRAPHICS_TOOLS_DIR")
    public static let SYSTEM_DEVELOPER_UTILITIES_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_UTILITIES_DIR")
    public static let SYSTEM_DEVELOPER_DEMOS_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_DEMOS_DIR")
    public static let SYSTEM_DEVELOPER_DOC_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_DOC_DIR")
    public static let SYSTEM_DEVELOPER_TOOLS_DOC_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_TOOLS_DOC_DIR")
    public static let SYSTEM_DEVELOPER_RELEASENOTES_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_RELEASENOTES_DIR")
    public static let SYSTEM_DEVELOPER_TOOLS_RELEASENOTES_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_TOOLS_RELEASENOTES_DIR")
    public static let SYSTEM_DEVELOPER_TOOLS = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_TOOLS")
    public static let DEVELOPER_TOOLS_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_TOOLS_DIR")
    public static let SYSTEM_DEVELOPER_USR_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_USR_DIR")
    public static let DEVELOPER_USR_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_USR_DIR")
    public static let SYSTEM_DEVELOPER_BIN_DIR = BuiltinMacros.declareStringMacro("SYSTEM_DEVELOPER_BIN_DIR")
    public static let DEVELOPER_BIN_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_BIN_DIR")
    public static let DEVELOPER_SDK_DIR = BuiltinMacros.declareStringMacro("DEVELOPER_SDK_DIR")
    public static let XCODE_APP_SUPPORT_DIR = BuiltinMacros.declareStringMacro("XCODE_APP_SUPPORT_DIR")
    public static let AVAILABLE_PLATFORMS = BuiltinMacros.declareStringListMacro("AVAILABLE_PLATFORMS")
    public static let DT_TOOLCHAIN_DIR = BuiltinMacros.declarePathMacro("DT_TOOLCHAIN_DIR")

    public static let DEVELOPER_INSTALL_DIR = BuiltinMacros.declarePathMacro("DEVELOPER_INSTALL_DIR")
    public static let XCODE_INSTALL_PATH = BuiltinMacros.declareStringMacro("XCODE_INSTALL_PATH")
    public static let DEVICE_DEVELOPER_DIR = BuiltinMacros.declareStringMacro("DEVICE_DEVELOPER_DIR")

    // MARK: Kernel Extension Specific Macros

    // These names really need to be made more specific now that "module" means something else than a kernel module.
    public static let MODULE_NAME = BuiltinMacros.declareStringMacro("MODULE_NAME")
    public static let MODULE_START = BuiltinMacros.declareStringMacro("MODULE_START")
    public static let MODULE_STOP = BuiltinMacros.declareStringMacro("MODULE_STOP")
    public static let MODULE_VERSION = BuiltinMacros.declareStringMacro("MODULE_VERSION")

    // MARK: Signing Macros

    public static let AD_HOC_CODE_SIGNING_ALLOWED = BuiltinMacros.declareBooleanMacro("AD_HOC_CODE_SIGNING_ALLOWED")
    public static let __AD_HOC_CODE_SIGNING_NOT_ALLOWED_SUPPLEMENTAL_MESSAGE = BuiltinMacros.declareStringMacro("__AD_HOC_CODE_SIGNING_NOT_ALLOWED_SUPPLEMENTAL_MESSAGE")
    public static let RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES = BuiltinMacros.declareBooleanMacro("RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES")
    public static let RUNTIME_EXCEPTION_ALLOW_JIT = BuiltinMacros.declareBooleanMacro("RUNTIME_EXCEPTION_ALLOW_JIT")
    public static let RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY = BuiltinMacros.declareBooleanMacro("RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY")
    public static let AUTOMATION_APPLE_EVENTS = BuiltinMacros.declareBooleanMacro("AUTOMATION_APPLE_EVENTS")
    public static let CODE_SIGNING_ALLOWED = BuiltinMacros.declareBooleanMacro("CODE_SIGNING_ALLOWED")
    public static let CODE_SIGNING_REQUIRED = BuiltinMacros.declareBooleanMacro("CODE_SIGNING_REQUIRED")
    public static let CODE_SIGNING_REQUIRES_TEAM = BuiltinMacros.declareBooleanMacro("CODE_SIGNING_REQUIRES_TEAM")
    public static let CODE_SIGN_ENTITLEMENTS = BuiltinMacros.declarePathMacro("CODE_SIGN_ENTITLEMENTS")
    public static let CODE_SIGN_ENTITLEMENTS_CONTENTS = BuiltinMacros.declareStringMacro("CODE_SIGN_ENTITLEMENTS_CONTENTS")
    public static let CODE_SIGN_IDENTIFIER = BuiltinMacros.declareStringMacro("CODE_SIGN_IDENTIFIER")
    public static let CODE_SIGN_IDENTITY = BuiltinMacros.declareStringMacro("CODE_SIGN_IDENTITY")
    public static let CODE_SIGN_INJECT_BASE_ENTITLEMENTS = BuiltinMacros.declareBooleanMacro("CODE_SIGN_INJECT_BASE_ENTITLEMENTS")
    public static let CODE_SIGN_LOCAL_EXECUTION_IDENTITY = BuiltinMacros.declareStringMacro("CODE_SIGN_LOCAL_EXECUTION_IDENTITY")
    public static let CODE_SIGN_KEYCHAIN = BuiltinMacros.declareStringMacro("CODE_SIGN_KEYCHAIN")
    public static let CODE_SIGN_RESTRICT = BuiltinMacros.declareBooleanMacro("CODE_SIGN_RESTRICT")
    public static let CODE_SIGN_RESOURCE_RULES_PATH = BuiltinMacros.declareStringMacro("CODE_SIGN_RESOURCE_RULES_PATH")
    public static let CODE_SIGN_STYLE = BuiltinMacros.declareStringMacro("CODE_SIGN_STYLE")
    public static let RUNTIME_EXCEPTION_DEBUGGING_TOOL = BuiltinMacros.declareBooleanMacro("RUNTIME_EXCEPTION_DEBUGGING_TOOL")
    public static let DIAGNOSE_MISSING_TARGET_DEPENDENCIES = BuiltinMacros.declareEnumMacro("DIAGNOSE_MISSING_TARGET_DEPENDENCIES") as EnumMacroDeclaration<BooleanWarningLevel>
    public static let RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION = BuiltinMacros.declareBooleanMacro("RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION")
    public static let DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS = BuiltinMacros.declareBooleanMacro("DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS")
    public static let RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = BuiltinMacros.declareBooleanMacro("RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION")
    public static let ENABLE_CLOUD_SIGNING = BuiltinMacros.declareBooleanMacro("ENABLE_CLOUD_SIGNING")

    public static let ENABLE_GENERIC_TASK_CACHING = BuiltinMacros.declareBooleanMacro("ENABLE_GENERIC_TASK_CACHING")
    public static let GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS = BuiltinMacros.declareBooleanMacro("GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS")

    // MARK: App Sandbox Settings
    public static let ENABLE_APP_SANDBOX = BuiltinMacros.declareBooleanMacro("ENABLE_APP_SANDBOX")
    public static let ENABLE_USER_SELECTED_FILES = BuiltinMacros.declareEnumMacro("ENABLE_USER_SELECTED_FILES") as EnumMacroDeclaration<FileAccessMode>
    public static let ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER = BuiltinMacros.declareEnumMacro("ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER") as EnumMacroDeclaration<FileAccessMode>
    public static let ENABLE_FILE_ACCESS_PICTURE_FOLDER = BuiltinMacros.declareEnumMacro("ENABLE_FILE_ACCESS_PICTURE_FOLDER") as EnumMacroDeclaration<FileAccessMode>
    public static let ENABLE_FILE_ACCESS_MUSIC_FOLDER = BuiltinMacros.declareEnumMacro("ENABLE_FILE_ACCESS_MUSIC_FOLDER") as EnumMacroDeclaration<FileAccessMode>
    public static let ENABLE_FILE_ACCESS_MOVIES_FOLDER = BuiltinMacros.declareEnumMacro("ENABLE_FILE_ACCESS_MOVIES_FOLDER") as EnumMacroDeclaration<FileAccessMode>
    public static let ENABLE_INCOMING_NETWORK_CONNECTIONS = BuiltinMacros.declareBooleanMacro("ENABLE_INCOMING_NETWORK_CONNECTIONS")
    public static let ENABLE_OUTGOING_NETWORK_CONNECTIONS = BuiltinMacros.declareBooleanMacro("ENABLE_OUTGOING_NETWORK_CONNECTIONS")
    public static let ENABLE_LIBRARY_VALIDATION = BuiltinMacros.declareBooleanMacro("ENABLE_LIBRARY_VALIDATION")
    public static let ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_AUDIO_INPUT")
    public static let ENABLE_RESOURCE_ACCESS_USB = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_USB")
    public static let ENABLE_RESOURCE_ACCESS_PRINTING = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_PRINTING")
    public static let ENABLE_RESOURCE_ACCESS_BLUETOOTH = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_BLUETOOTH")
    public static let ENABLE_RESOURCE_ACCESS_CALENDARS = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_CALENDARS")
    public static let ENABLE_RESOURCE_ACCESS_CAMERA = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_CAMERA")
    public static let ENABLE_RESOURCE_ACCESS_CONTACTS = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_CONTACTS")
    public static let ENABLE_RESOURCE_ACCESS_LOCATION = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_LOCATION")
    public static let ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY = BuiltinMacros.declareBooleanMacro("ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY")
    public static let ENTITLEMENTS_ALLOWED = BuiltinMacros.declareBooleanMacro("ENTITLEMENTS_ALLOWED")
    public static let ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW = BuiltinMacros.declareBooleanMacro("ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW")
    public static let ENTITLEMENTS_DESTINATION = BuiltinMacros.declareEnumMacro("ENTITLEMENTS_DESTINATION") as EnumMacroDeclaration<EntitlementsDestination>
    public static let ENTITLEMENTS_REQUIRED = BuiltinMacros.declareBooleanMacro("ENTITLEMENTS_REQUIRED")
    public static let EXPANDED_CODE_SIGN_IDENTITY = BuiltinMacros.declareStringMacro("EXPANDED_CODE_SIGN_IDENTITY")
    public static let EXPANDED_CODE_SIGN_IDENTITY_NAME = BuiltinMacros.declareStringMacro("EXPANDED_CODE_SIGN_IDENTITY_NAME")
    public static let EXPANDED_PROVISIONING_PROFILE = BuiltinMacros.declareStringMacro("EXPANDED_PROVISIONING_PROFILE")
    public static let LAUNCH_CONSTRAINT_PARENT = BuiltinMacros.declareStringMacro("LAUNCH_CONSTRAINT_PARENT")
    public static let LAUNCH_CONSTRAINT_RESPONSIBLE = BuiltinMacros.declareStringMacro("LAUNCH_CONSTRAINT_RESPONSIBLE")
    public static let LAUNCH_CONSTRAINT_SELF = BuiltinMacros.declareStringMacro("LAUNCH_CONSTRAINT_SELF")
    public static let LD_ENTITLEMENTS_SECTION = BuiltinMacros.declareStringMacro("LD_ENTITLEMENTS_SECTION")
    public static let LD_ENTITLEMENTS_SECTION_DER = BuiltinMacros.declareStringMacro("LD_ENTITLEMENTS_SECTION_DER")
    public static let LIBRARY_LOAD_CONSTRAINT = BuiltinMacros.declareStringMacro("LIBRARY_LOAD_CONSTRAINT")
    public static let SigningCert = BuiltinMacros.declareStringMacro("SigningCert")
    public static let InfoPlistPath = BuiltinMacros.declarePathMacro("InfoPlistPath")

    // Signing macro to allow for updating your entitlement. This is something that should not be done, but we expose it to silence the error for those paving their own path. This is mostly a backwards-compat change. We need a better solution all-together for allowing people to generate entitlements files.
    public static let CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION = BuiltinMacros.declareBooleanMacro("CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION")

    // MARK: Sanitizer macros

    public static let ENABLE_ADDRESS_SANITIZER = BuiltinMacros.declareBooleanMacro("ENABLE_ADDRESS_SANITIZER")
    public static let ENABLE_THREAD_SANITIZER = BuiltinMacros.declareBooleanMacro("ENABLE_THREAD_SANITIZER")
    public static let ENABLE_UNDEFINED_BEHAVIOR_SANITIZER = BuiltinMacros.declareBooleanMacro("ENABLE_UNDEFINED_BEHAVIOR_SANITIZER")
    public static let ENABLE_SYSTEM_SANITIZERS = BuiltinMacros.declareBooleanMacro("ENABLE_SYSTEM_SANITIZERS")

    // MARK: Unit testing macros

    public static let INTERNAL_AUTOMATION_SUPPORT_FRAMEWORK_PATH = BuiltinMacros.declareStringMacro("INTERNAL_AUTOMATION_SUPPORT_FRAMEWORK_PATH")
    public static let INTERNAL_TEST_LIBRARIES_OVERRIDE_PATH = BuiltinMacros.declareStringMacro("INTERNAL_TEST_LIBRARIES_OVERRIDE_PATH")
    public static let INTERNAL_TESTING_FRAMEWORK_PATH = BuiltinMacros.declareStringMacro("INTERNAL_TESTING_FRAMEWORK_PATH")
    public static let TEST_BUILD_STYLE = BuiltinMacros.declareStringMacro("TEST_BUILD_STYLE")
    public static let TEST_HOST = BuiltinMacros.declareStringMacro("TEST_HOST")
    public static let TEST_FRAMEWORK_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("TEST_FRAMEWORK_SEARCH_PATHS")
    public static let TEST_PRIVATE_FRAMEWORK_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("TEST_PRIVATE_FRAMEWORK_SEARCH_PATHS")
    public static let TEST_LIBRARY_SEARCH_PATHS = BuiltinMacros.declareStringListMacro("TEST_LIBRARY_SEARCH_PATHS")
    public static let TEST_FRAMEWORK_DEVELOPER_VARIANT_SUBPATH = BuiltinMacros.declareStringMacro("TEST_FRAMEWORK_DEVELOPER_VARIANT_SUBPATH")
    public static let XCTRUNNER_PATH = BuiltinMacros.declareStringMacro("XCTRUNNER_PATH")
    public static let XCTRUNNER_PRODUCT_NAME = BuiltinMacros.declareStringMacro("XCTRUNNER_PRODUCT_NAME")
    public static let SKIP_COPYING_TEST_FRAMEWORKS = BuiltinMacros.declareBooleanMacro("SKIP_COPYING_TEST_FRAMEWORKS")

    // MARK: Mergeable libraries macros

    public static let AUTOMATICALLY_MERGE_DEPENDENCIES = BuiltinMacros.declareBooleanMacro("AUTOMATICALLY_MERGE_DEPENDENCIES")
    public static let MERGEABLE_LIBRARY = BuiltinMacros.declareBooleanMacro("MERGEABLE_LIBRARY")
    public static let DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES = BuiltinMacros.declareBooleanMacro("DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES")
    public static let MERGE_LINKED_LIBRARIES = BuiltinMacros.declareBooleanMacro("MERGE_LINKED_LIBRARIES")
    public static let MERGED_BINARY_TYPE = BuiltinMacros.declareEnumMacro("MERGED_BINARY_TYPE") as EnumMacroDeclaration<MergedBinaryType>
    public static let MAKE_MERGEABLE = BuiltinMacros.declareBooleanMacro("MAKE_MERGEABLE")

    // MARK: Task Planning Macros

    public static let AGGREGATE_TRACKED_DOMAINS = BuiltinMacros.declareBooleanMacro("AGGREGATE_TRACKED_DOMAINS")
    public static let ALLOW_BUILD_REQUEST_OVERRIDES = BuiltinMacros.declareBooleanMacro("ALLOW_BUILD_REQUEST_OVERRIDES")
    public static let ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES = BuiltinMacros.declareBooleanMacro("ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES")
    public static let DIAGNOSE_SKIP_DEPENDENCIES_USAGE = BuiltinMacros.declareBooleanMacro("DIAGNOSE_SKIP_DEPENDENCIES_USAGE")
    public static let ALLOW_TARGET_PLATFORM_SPECIALIZATION = BuiltinMacros.declareBooleanMacro("ALLOW_TARGET_PLATFORM_SPECIALIZATION")
    public static let ALLOW_UNSUPPORTED_TEXT_BASED_API = BuiltinMacros.declareBooleanMacro("ALLOW_UNSUPPORTED_TEXT_BASED_API")
    public static let ALL_OTHER_LDFLAGS = BuiltinMacros.declareStringListMacro("ALL_OTHER_LDFLAGS")
    public static let ALL_SETTINGS = BuiltinMacros.declareStringListMacro("ALL_SETTINGS")
    public static let ALTERNATE_GROUP = BuiltinMacros.declareStringMacro("ALTERNATE_GROUP")
    public static let ALTERNATE_MODE = BuiltinMacros.declareStringMacro("ALTERNATE_MODE")
    public static let ALTERNATE_OWNER = BuiltinMacros.declareStringMacro("ALTERNATE_OWNER")
    public static let ALTERNATE_PERMISSIONS_FILES = BuiltinMacros.declareStringListMacro("ALTERNATE_PERMISSIONS_FILES")
    public static let ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = BuiltinMacros.declareBooleanMacro("ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES")
    public static let ALWAYS_SEARCH_USER_PATHS = BuiltinMacros.declareBooleanMacro("ALWAYS_SEARCH_USER_PATHS")
    public static let ALWAYS_USE_SEPARATE_HEADERMAPS = BuiltinMacros.declareBooleanMacro("ALWAYS_USE_SEPARATE_HEADERMAPS")
    public static let APP_INTENTS_METADATA_PATH = BuiltinMacros.declareStringMacro("APP_INTENTS_METADATA_PATH")
    public static let APP_INTENTS_DEPLOYMENT_POSTPROCESSING = BuiltinMacros.declareBooleanMacro("APP_INTENTS_DEPLOYMENT_POSTPROCESSING")
    public static let APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING = BuiltinMacros.declareBooleanMacro("APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING")
    public static let APPLICATION_EXTENSION_API_ONLY = BuiltinMacros.declareBooleanMacro("APPLICATION_EXTENSION_API_ONLY")
    public static let __APPLICATION_EXTENSION_API_DOWNGRADE_APPEX_ERROR = BuiltinMacros.declareBooleanMacro("__APPLICATION_EXTENSION_API_DOWNGRADE_APPEX_ERROR")
    public static let APPLY_RULES_IN_COPY_FILES = BuiltinMacros.declareBooleanMacro("APPLY_RULES_IN_COPY_FILES")
    public static let APPLY_RULES_IN_COPY_HEADERS = BuiltinMacros.declareBooleanMacro("APPLY_RULES_IN_COPY_HEADERS")
    public static let APPLY_RULES_IN_INSTALLAPI = BuiltinMacros.declareBooleanMacro("APPLY_RULES_IN_INSTALLAPI")
    public static let ARCHS_STANDARD = BuiltinMacros.declareStringListMacro("ARCHS_STANDARD")
    public static let ARCHS_STANDARD_32_64_BIT_PRE_XCODE_3_1 = BuiltinMacros.declareStringListMacro("ARCHS_STANDARD_32_64_BIT_PRE_XCODE_3_1")
    public static let ARCHS_STANDARD_32_BIT_PRE_XCODE_3_1 = BuiltinMacros.declareStringListMacro("ARCHS_STANDARD_32_BIT_PRE_XCODE_3_1")
    public static let ARCHS_STANDARD_64_BIT = BuiltinMacros.declareStringListMacro("ARCHS_STANDARD_64_BIT")
    public static let ARCHS_STANDARD_INCLUDING_64_BIT = BuiltinMacros.declareStringListMacro("ARCHS_STANDARD_INCLUDING_64_BIT")
    public static let ASSETCATALOG_COMPILER_DEPENDENCY_INFO_FILE = BuiltinMacros.declarePathMacro("ASSETCATALOG_COMPILER_DEPENDENCY_INFO_FILE")
    public static let ASSETCATALOG_COMPILER_INCLUDE_STICKER_CONTENT = BuiltinMacros.declareBooleanMacro("ASSETCATALOG_COMPILER_INCLUDE_STICKER_CONTENT")
    public static let ASSETCATALOG_COMPILER_INFOPLIST_CONTENT_FILE = BuiltinMacros.declarePathMacro("ASSETCATALOG_COMPILER_INFOPLIST_CONTENT_FILE")
    public static let ASSETCATALOG_COMPILER_INPUTS = BuiltinMacros.declarePathListMacro("ASSETCATALOG_COMPILER_INPUTS")
    public static let ASSETCATALOG_COMPILER_STICKER_PACK_STRINGS = BuiltinMacros.declarePathListMacro("ASSETCATALOG_COMPILER_STICKER_PACK_STRINGS")
    public static let ASSETCATALOG_COMPILER_BUNDLE_IDENTIFIER = BuiltinMacros.declareStringMacro("ASSETCATALOG_COMPILER_BUNDLE_IDENTIFIER")
    public static let ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = BuiltinMacros.declareBooleanMacro("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS")
    public static let ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = BuiltinMacros.declareBooleanMacro("ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS")
    public static let ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS = BuiltinMacros.declareStringListMacro("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS")
    public static let ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_WARNINGS = BuiltinMacros.declareBooleanMacro("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_WARNINGS")
    public static let ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_ERRORS = BuiltinMacros.declareBooleanMacro("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_ERRORS")
    public static let ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_BACKWARDS_DEPLOYMENT_SUPPORT = BuiltinMacros.declareStringMacro("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_BACKWARDS_DEPLOYMENT_SUPPORT")
    public static let ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOLS_PATH = BuiltinMacros.declarePathMacro("ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOLS_PATH")
    public static let ASSETCATALOG_COMPILER_GENERATE_OBJC_ASSET_SYMBOLS_PATH = BuiltinMacros.declarePathMacro("ASSETCATALOG_COMPILER_GENERATE_OBJC_ASSET_SYMBOLS_PATH")
    public static let ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH = BuiltinMacros.declarePathMacro("ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH")
    public static let ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT = BuiltinMacros.declareBooleanMacro("ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT")
    public static let ASSETCATALOG_EXEC = BuiltinMacros.declarePathMacro("ASSETCATALOG_EXEC")
    public static let AdditionalCommandLineArguments = BuiltinMacros.declareStringListMacro("AdditionalCommandLineArguments")
    public static let BLOCKLISTS_PATH = BuiltinMacros.declareStringMacro("BLOCKLISTS_PATH")
    public static let BUILD_ACTIVE_RESOURCES_ONLY = BuiltinMacros.declareBooleanMacro("BUILD_ACTIVE_RESOURCES_ONLY")
    public static let BUILD_DIR = BuiltinMacros.declarePathMacro("BUILD_DIR")
    public static let BUILD_LIBRARY_FOR_DISTRIBUTION = BuiltinMacros.declareBooleanMacro("BUILD_LIBRARY_FOR_DISTRIBUTION")
    public static let BUILD_PACKAGE_FOR_DISTRIBUTION = BuiltinMacros.declareBooleanMacro("BUILD_PACKAGE_FOR_DISTRIBUTION")
    public static let BUILD_VARIANTS = BuiltinMacros.declareStringListMacro("BUILD_VARIANTS")
    public static let BuiltBinaryPath = BuiltinMacros.declareStringMacro("BuiltBinaryPath")
    public static let BUNDLE_FORMAT = BuiltinMacros.declareStringMacro("BUNDLE_FORMAT")
    public static let BUNDLE_LOADER = BuiltinMacros.declarePathMacro("BUNDLE_LOADER")
    public static let C_COMPILER_LAUNCHER = BuiltinMacros.declareStringMacro("C_COMPILER_LAUNCHER")
    public static let CC = BuiltinMacros.declarePathMacro("CC")
    public static let CFBundleIdentifier = BuiltinMacros.declareStringMacro("CFBundleIdentifier")
    public static let CHMOD = BuiltinMacros.declarePathMacro("CHMOD")
    public static let CHOWN = BuiltinMacros.declarePathMacro("CHOWN")
    public static let COMPILER_WORKING_DIRECTORY = BuiltinMacros.declareStringMacro("COMPILER_WORKING_DIRECTORY")
    public static let CLANG_CACHE_ENABLE_LAUNCHER = BuiltinMacros.declareBooleanMacro("CLANG_CACHE_ENABLE_LAUNCHER")
    public static let CLANG_CACHE_FALLBACK_IF_UNAVAILABLE = BuiltinMacros.declareBooleanMacro("CLANG_CACHE_FALLBACK_IF_UNAVAILABLE")
    public static let CLANG_CXX_LIBRARY = BuiltinMacros.declareStringMacro("CLANG_CXX_LIBRARY")
    public static let CLANG_DIAGNOSTICS_FILE = BuiltinMacros.declarePathMacro("CLANG_DIAGNOSTICS_FILE")
    public static let CLANG_DISABLE_SERIALIZED_DIAGNOSTICS = BuiltinMacros.declareBooleanMacro("CLANG_DISABLE_SERIALIZED_DIAGNOSTICS")
    public static let CLANG_ENABLE_MODULES = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_MODULES")
    public static let CLANG_DISABLE_CXX_MODULES = BuiltinMacros.declareBooleanMacro("CLANG_DISABLE_CXX_MODULES")
    public static let CLANG_ENABLE_MODULE_DEBUGGING = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_MODULE_DEBUGGING")
    public static let CLANG_ENABLE_OBJC_ARC = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_OBJC_ARC")
    public static let CLANG_ENABLE_EXPLICIT_MODULES = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_EXPLICIT_MODULES")
    public static let _EXPERIMENTAL_CLANG_EXPLICIT_MODULES = BuiltinMacros.declareBooleanMacro("_EXPERIMENTAL_CLANG_EXPLICIT_MODULES")
    public static let CLANG_ENABLE_EXPLICIT_MODULES_OBJECT_FILE_VERIFIER = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_EXPLICIT_MODULES_OBJECT_FILE_VERIFIER")
    public static let CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER")
    public static let CLANG_EXPLICIT_MODULES_LIBCLANG_PATH = BuiltinMacros.declareStringMacro("CLANG_EXPLICIT_MODULES_LIBCLANG_PATH")
    public static let CLANG_EXPLICIT_MODULES_IGNORE_LIBCLANG_VERSION_MISMATCH = BuiltinMacros.declareBooleanMacro("CLANG_EXPLICIT_MODULES_IGNORE_LIBCLANG_VERSION_MISMATCH")
    public static let CLANG_EXPLICIT_MODULES_OUTPUT_PATH = BuiltinMacros.declareStringMacro("CLANG_EXPLICIT_MODULES_OUTPUT_PATH")
    public static let SWIFT_EXPLICIT_MODULES_OUTPUT_PATH = BuiltinMacros.declareStringMacro("SWIFT_EXPLICIT_MODULES_OUTPUT_PATH")
    public static let CLANG_ENABLE_COMPILE_CACHE = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_COMPILE_CACHE")
    public static let CLANG_CACHE_FINE_GRAINED_OUTPUTS = BuiltinMacros.declareEnumMacro("CLANG_CACHE_FINE_GRAINED_OUTPUTS") as EnumMacroDeclaration<FineGrainedCachingSetting>
    public static let CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION = BuiltinMacros.declareEnumMacro("CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION") as EnumMacroDeclaration<FineGrainedCachingVerificationSetting>
    public static let CLANG_DISABLE_DEPENDENCY_INFO_FILE = BuiltinMacros.declareBooleanMacro("CLANG_DISABLE_DEPENDENCY_INFO_FILE")
    public static let CLANG_ENABLE_PREFIX_MAPPING = BuiltinMacros.declareBooleanMacro("CLANG_ENABLE_PREFIX_MAPPING")
    public static let CLANG_OTHER_PREFIX_MAPPINGS = BuiltinMacros.declareStringListMacro("CLANG_OTHER_PREFIX_MAPPINGS")
    public static let CLANG_GENERATE_OPTIMIZATION_REMARKS = BuiltinMacros.declareBooleanMacro("CLANG_GENERATE_OPTIMIZATION_REMARKS")
    public static let CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER = BuiltinMacros.declareStringMacro("CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER")
    public static let CLANG_IMPORT_PREFIX_HEADER_AS_MODULE = BuiltinMacros.declareBooleanMacro("CLANG_IMPORT_PREFIX_HEADER_AS_MODULE")
    public static let CLANG_INDEX_STORE_ENABLE = BuiltinMacros.declareBooleanMacro("CLANG_INDEX_STORE_ENABLE")
    public static let CLANG_INDEX_STORE_PATH = BuiltinMacros.declarePathMacro("CLANG_INDEX_STORE_PATH")
    public static let CLANG_INSTRUMENT_FOR_OPTIMIZATION_PROFILING = BuiltinMacros.declareBooleanMacro("CLANG_INSTRUMENT_FOR_OPTIMIZATION_PROFILING")
    public static let CLANG_MODULES_BUILD_SESSION_FILE = BuiltinMacros.declareStringMacro("CLANG_MODULES_BUILD_SESSION_FILE")
    public static let CLANG_MODULE_LSV = BuiltinMacros.declareBooleanMacro("CLANG_MODULE_LSV")
    public static let CLANG_OBJC_MODERNIZE_DIR = BuiltinMacros.declareStringMacro("CLANG_OBJC_MODERNIZE_DIR")
    public static let CLANG_OPTIMIZATION_PROFILE_FILE = BuiltinMacros.declarePathMacro("CLANG_OPTIMIZATION_PROFILE_FILE")
    public static let CLANG_STATIC_ANALYZER_MODE = BuiltinMacros.declareStringMacro("CLANG_STATIC_ANALYZER_MODE")
    public static let CLANG_STAT_CACHE_EXEC = BuiltinMacros.declareStringMacro("CLANG_STAT_CACHE_EXEC")
    public static let CLANG_TARGET_TRIPLE_VARIANTS = BuiltinMacros.declareStringListMacro("CLANG_TARGET_TRIPLE_VARIANTS")
    public static let CLANG_USE_OPTIMIZATION_PROFILE = BuiltinMacros.declareBooleanMacro("CLANG_USE_OPTIMIZATION_PROFILE")
    public static let CLANG_USE_RESPONSE_FILE = BuiltinMacros.declareBooleanMacro("CLANG_USE_RESPONSE_FILE")
    public static let CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = BuiltinMacros.declareStringMacro("CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING")
    public static let CLANG_WARN_COMMA = BuiltinMacros.declareStringMacro("CLANG_WARN_COMMA")
    public static let CLANG_WARN_FLOAT_CONVERSION = BuiltinMacros.declareStringMacro("CLANG_WARN_FLOAT_CONVERSION")
    public static let CLANG_WARN_IMPLICIT_FALLTHROUGH = BuiltinMacros.declareStringMacro("CLANG_WARN_IMPLICIT_FALLTHROUGH")
    public static let CLANG_WARN_NON_LITERAL_NULL_CONVERSION = BuiltinMacros.declareStringMacro("CLANG_WARN_NON_LITERAL_NULL_CONVERSION")
    public static let CLANG_WARN_OBJC_LITERAL_CONVERSION = BuiltinMacros.declareStringMacro("CLANG_WARN_OBJC_LITERAL_CONVERSION")
    public static let CLANG_WARN_STRICT_PROTOTYPES = BuiltinMacros.declareStringMacro("CLANG_WARN_STRICT_PROTOTYPES")
    public static let CLONE_HEADERS = BuiltinMacros.declareBooleanMacro("CLONE_HEADERS")
    public static let CODESIGNING_FOLDER_PATH = BuiltinMacros.declarePathMacro("CODESIGNING_FOLDER_PATH")
    public static let CODESIGN = BuiltinMacros.declareStringMacro("CODESIGN")
    public static let CODESIGN_ALLOCATE = BuiltinMacros.declareStringMacro("CODESIGN_ALLOCATE")
    public static let COMBINE_HIDPI_IMAGES = BuiltinMacros.declareBooleanMacro("COMBINE_HIDPI_IMAGES")
    public static let COMPILATION_CACHE_ENABLE_DETACHED_KEY_QUERIES = BuiltinMacros.declareBooleanMacro("COMPILATION_CACHE_ENABLE_DETACHED_KEY_QUERIES")
    public static let COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS = BuiltinMacros.declareBooleanMacro("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS")
    public static let COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES = BuiltinMacros.declareBooleanMacro("COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES")
    public static let COMPILATION_CACHE_ENABLE_PLUGIN = BuiltinMacros.declareBooleanMacro("COMPILATION_CACHE_ENABLE_PLUGIN")
    public static let COMPILATION_CACHE_ENABLE_STRICT_CAS_ERRORS = BuiltinMacros.declareBooleanMacro("COMPILATION_CACHE_ENABLE_STRICT_CAS_ERRORS")
    public static let COMPILATION_CACHE_KEEP_CAS_DIRECTORY = BuiltinMacros.declareBooleanMacro("COMPILATION_CACHE_KEEP_CAS_DIRECTORY")
    public static let COMPILATION_CACHE_CAS_PATH = BuiltinMacros.declareStringMacro("COMPILATION_CACHE_CAS_PATH")
    public static let COMPILATION_CACHE_LIMIT_PERCENT = BuiltinMacros.declareStringMacro("COMPILATION_CACHE_LIMIT_PERCENT")
    public static let COMPILATION_CACHE_LIMIT_SIZE = BuiltinMacros.declareStringMacro("COMPILATION_CACHE_LIMIT_SIZE")
    public static let COMPILATION_CACHE_PLUGIN_PATH = BuiltinMacros.declareStringMacro("COMPILATION_CACHE_PLUGIN_PATH")
    public static let COMPILATION_CACHE_REMOTE_SERVICE_PATH = BuiltinMacros.declareStringMacro("COMPILATION_CACHE_REMOTE_SERVICE_PATH")
    public static let COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES = BuiltinMacros.declareStringListMacro("COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES")
    public static let COMPRESS_PNG_FILES = BuiltinMacros.declareBooleanMacro("COMPRESS_PNG_FILES")
    public static let CONTENTS_FOLDER_PATH = BuiltinMacros.declarePathMacro("CONTENTS_FOLDER_PATH")
    public static let COPYING_PRESERVES_HFS_DATA = BuiltinMacros.declareBooleanMacro("COPYING_PRESERVES_HFS_DATA")
    public static let COPY_HEADERS_RUN_UNIFDEF = BuiltinMacros.declareBooleanMacro("COPY_HEADERS_RUN_UNIFDEF")
    public static let COPY_HEADERS_UNIFDEF_FLAGS = BuiltinMacros.declareStringListMacro("COPY_HEADERS_UNIFDEF_FLAGS")
    public static let COPY_PHASE_STRIP = BuiltinMacros.declareBooleanMacro("COPY_PHASE_STRIP")
    public static let COREML_CODEGEN_LANGUAGE = BuiltinMacros.declareStringMacro("COREML_CODEGEN_LANGUAGE")
    public static let COREML_CODEGEN_SWIFT_GLOBAL_MODULE = BuiltinMacros.declareBooleanMacro("COREML_CODEGEN_SWIFT_GLOBAL_MODULE")
    public static let COREML_CODEGEN_SWIFT_VERSION = BuiltinMacros.declareStringMacro("COREML_CODEGEN_SWIFT_VERSION")
    public static let CP = BuiltinMacros.declarePathMacro("CP")
    public static let CPLUSPLUS = BuiltinMacros.declarePathMacro("CPLUSPLUS")
    public static let CPP_HEADERMAP_FILE = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_FILE")
    public static let CPP_HEADERMAP_FILE_FOR_ALL_NON_FRAMEWORK_TARGET_HEADERS = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_FILE_FOR_ALL_NON_FRAMEWORK_TARGET_HEADERS")
    public static let CPP_HEADERMAP_FILE_FOR_ALL_TARGET_HEADERS = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_FILE_FOR_ALL_TARGET_HEADERS")
    public static let CPP_HEADERMAP_FILE_FOR_GENERATED_FILES = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_FILE_FOR_GENERATED_FILES")
    public static let CPP_HEADERMAP_FILE_FOR_OWN_TARGET_HEADERS = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_FILE_FOR_OWN_TARGET_HEADERS")
    public static let CPP_HEADERMAP_FILE_FOR_PROJECT_FILES = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_FILE_FOR_PROJECT_FILES")
    public static let CPP_HEADERMAP_PRODUCT_HEADERS_VFS_FILE = BuiltinMacros.declarePathMacro("CPP_HEADERMAP_PRODUCT_HEADERS_VFS_FILE")
    public static let CPP_HEADER_SYMLINKS_DIR = BuiltinMacros.declarePathMacro("CPP_HEADER_SYMLINKS_DIR")
    public static let CPP_OTHER_PREPROCESSOR_FLAGS = BuiltinMacros.declareStringListMacro("CPP_OTHER_PREPROCESSOR_FLAGS")
    public static let CPP_PREFIX_HEADER = BuiltinMacros.declareStringMacro("CPP_PREFIX_HEADER")
    public static let CPP_PREPROCESSOR_DEFINITIONS = BuiltinMacros.declareStringListMacro("CPP_PREPROCESSOR_DEFINITIONS")
    public static let CREATE_INFOPLIST_SECTION_IN_BINARY = BuiltinMacros.declareBooleanMacro("CREATE_INFOPLIST_SECTION_IN_BINARY")
    public static let CREATE_UNIVERSAL_STATIC_LIBRARY_USING_LIBTOOL = BuiltinMacros.declareBooleanMacro("CREATE_UNIVERSAL_STATIC_LIBRARY_USING_LIBTOOL")
    public static let CURRENT_ARCH = BuiltinMacros.declareStringMacro("CURRENT_ARCH")
    public static let CURRENT_PROJECT_VERSION = BuiltinMacros.declareStringMacro("CURRENT_PROJECT_VERSION")
    public static let CURRENT_VARIANT = BuiltinMacros.declareStringMacro("CURRENT_VARIANT")
    public static let CURRENT_VERSION = BuiltinMacros.declareStringMacro("CURRENT_VERSION")
    public static let DEAD_CODE_STRIPPING = BuiltinMacros.declareBooleanMacro("DEAD_CODE_STRIPPING")
    public static let DEBUG_INFORMATION_FORMAT = BuiltinMacros.declareStringMacro("DEBUG_INFORMATION_FORMAT")
    public static let DEFAULT_COMPILER = BuiltinMacros.declareStringMacro("DEFAULT_COMPILER")
    public static let DEFAULT_KEXT_INSTALL_PATH = BuiltinMacros.declareStringMacro("DEFAULT_KEXT_INSTALL_PATH")
    public static let DEFINES_MODULE = BuiltinMacros.declareBooleanMacro("DEFINES_MODULE")
    public static let DEPENDENCY_SCOPE_INCLUDES_DIRECT_DEPENDENCIES = BuiltinMacros.declareBooleanMacro("DEPENDENCY_SCOPE_INCLUDES_DIRECT_DEPENDENCIES")
    public static let DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = BuiltinMacros.declareBooleanMacro("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER")
    public static let __DIAGNOSE_DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER_ERROR = BuiltinMacros.declareBooleanMacro("__DIAGNOSE_DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER_ERROR")
    public static let DERIVED_FILES_DIR = BuiltinMacros.declarePathMacro("DERIVED_FILES_DIR")
    public static let DERIVED_FILE_DIR = BuiltinMacros.declarePathMacro("DERIVED_FILE_DIR")
    public static let DERIVED_SOURCES_DIR = BuiltinMacros.declarePathMacro("DERIVED_SOURCES_DIR")
    public static let DEVELOPMENT_TEAM = BuiltinMacros.declareStringMacro("DEVELOPMENT_TEAM")
    public static let DIAGNOSE_LOCALIZATION_FILE_EXCLUSION = BuiltinMacros.declareEnumMacro("DIAGNOSE_LOCALIZATION_FILE_EXCLUSION") as EnumMacroDeclaration<BooleanWarningLevel>
    public static let __DIAGNOSE_DEPRECATED_ARCHS = BuiltinMacros.declareBooleanMacro("__DIAGNOSE_DEPRECATED_ARCHS")
    public static let DIFF = BuiltinMacros.declarePathMacro("DIFF")
    public static let _DISCOVER_COMMAND_LINE_LINKER_INPUTS = BuiltinMacros.declareBooleanMacro("_DISCOVER_COMMAND_LINE_LINKER_INPUTS")
    public static let _DISCOVER_COMMAND_LINE_LINKER_INPUTS_INCLUDE_WL = BuiltinMacros.declareBooleanMacro("_DISCOVER_COMMAND_LINE_LINKER_INPUTS_INCLUDE_WL")
    public static let DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC = BuiltinMacros.declareBooleanMacro("DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC")
    public static let DISABLE_INFOPLIST_PLATFORM_PROCESSING = BuiltinMacros.declareBooleanMacro("DISABLE_INFOPLIST_PLATFORM_PROCESSING")
    public static let DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING = BuiltinMacros.declareBooleanMacro("DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING")
    public static let DISABLE_STALE_FILE_REMOVAL = BuiltinMacros.declareBooleanMacro("DISABLE_STALE_FILE_REMOVAL")
    public static let DISABLE_TEST_HOST_PLATFORM_PROCESSING = BuiltinMacros.declareBooleanMacro("DISABLE_TEST_HOST_PLATFORM_PROCESSING")
    public static let DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION = BuiltinMacros.declareBooleanMacro("DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION")
    public static let DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS = BuiltinMacros.declareBooleanMacro("DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS")
    public static let DONT_GENERATE_INFOPLIST_FILE = BuiltinMacros.declareBooleanMacro("DONT_GENERATE_INFOPLIST_FILE")
    public static let DONT_RUN_SWIFT_STDLIB_TOOL = BuiltinMacros.declareBooleanMacro("DONT_RUN_SWIFT_STDLIB_TOOL")
    public static let DOWNGRADE_CODESIGN_MISSING_INFO_PLIST_ERROR = BuiltinMacros.declareBooleanMacro("DOWNGRADE_CODESIGN_MISSING_INFO_PLIST_ERROR")
    public static let DRIVERKIT_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("DRIVERKIT_DEPLOYMENT_TARGET")
    public static let DSYMUTIL_VARIANT_SUFFIX = BuiltinMacros.declareStringMacro("DSYMUTIL_VARIANT_SUFFIX")
    public static let DSYMUTIL_DSYM_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("DSYMUTIL_DSYM_SEARCH_PATHS")
    public static let DSYMUTIL_QUIET_OPERATION = BuiltinMacros.declareBooleanMacro("DSYMUTIL_QUIET_OPERATION")
    public static let DWARF_DSYM_FILE_NAME = BuiltinMacros.declareStringMacro("DWARF_DSYM_FILE_NAME")
    public static let DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT = BuiltinMacros.declareBooleanMacro("DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT")
    public static let DWARF_DSYM_FOLDER_PATH = BuiltinMacros.declarePathMacro("DWARF_DSYM_FOLDER_PATH")
    public static let DYLIB_COMPATIBILITY_VERSION = BuiltinMacros.declareStringMacro("DYLIB_COMPATIBILITY_VERSION")
    public static let DYLIB_CURRENT_VERSION = BuiltinMacros.declareStringMacro("DYLIB_CURRENT_VERSION")
    public static let DYLIB_INSTALL_NAME_BASE = BuiltinMacros.declareStringMacro("DYLIB_INSTALL_NAME_BASE")
    public static let DYNAMIC_LIBRARY_EXTENSION = BuiltinMacros.declareStringMacro("DYNAMIC_LIBRARY_EXTENSION")
    public static let DerivedFilesDir = BuiltinMacros.declareStringMacro("DerivedFilesDir")
    public static let EAGER_COMPILATION_ALLOW_SCRIPTS = BuiltinMacros.declareBooleanMacro("EAGER_COMPILATION_ALLOW_SCRIPTS")
    public static let EAGER_COMPILATION_DISABLE = BuiltinMacros.declareBooleanMacro("EAGER_COMPILATION_DISABLE")
    public static let EAGER_LINKING = BuiltinMacros.declareBooleanMacro("EAGER_LINKING")
    public static let EAGER_LINKING_INTERMEDIATE_TBD_DIR = BuiltinMacros.declarePathMacro("EAGER_LINKING_INTERMEDIATE_TBD_DIR")
    public static let EAGER_LINKING_INTERMEDIATE_TBD_PATH = BuiltinMacros.declareStringMacro("EAGER_LINKING_INTERMEDIATE_TBD_PATH")
    public static let EAGER_PARALLEL_COMPILATION_DISABLE = BuiltinMacros.declareBooleanMacro("EAGER_PARALLEL_COMPILATION_DISABLE")
    public static let EAGER_COMPILATION_REQUIRE = BuiltinMacros.declareBooleanMacro("EAGER_COMPILATION_REQUIRE")
    public static let EAGER_LINKING_REQUIRE = BuiltinMacros.declareBooleanMacro("EAGER_LINKING_REQUIRE")
    public static let EMBEDDED_CONTENT_CONTAINS_SWIFT = BuiltinMacros.declareBooleanMacro("EMBEDDED_CONTENT_CONTAINS_SWIFT")
    public static let EMBEDDED_PROFILE_NAME = BuiltinMacros.declareStringMacro("EMBEDDED_PROFILE_NAME")
    public static let EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES = BuiltinMacros.declareStringListMacro("EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES")
    public static let EMIT_FRONTEND_COMMAND_LINES = BuiltinMacros.declareBooleanMacro("EMIT_FRONTEND_COMMAND_LINES")
    public static let ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING = BuiltinMacros.declareBooleanMacro("ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING")
    public static let ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING = BuiltinMacros.declareBooleanMacro("ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING")
    public static let ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS = BuiltinMacros.declareBooleanMacro("ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS")
    public static let ENABLE_APPLE_KEXT_CODE_GENERATION = BuiltinMacros.declareBooleanMacro("ENABLE_APPLE_KEXT_CODE_GENERATION")
    public static let ENABLE_DEFAULT_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_DEFAULT_SEARCH_PATHS")
    public static let ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS")
    public static let ENABLE_DEFAULT_SEARCH_PATHS_IN_FRAMEWORK_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_DEFAULT_SEARCH_PATHS_IN_FRAMEWORK_SEARCH_PATHS")
    public static let ENABLE_DEFAULT_SEARCH_PATHS_IN_LIBRARY_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_DEFAULT_SEARCH_PATHS_IN_LIBRARY_SEARCH_PATHS")
    public static let ENABLE_DEFAULT_SEARCH_PATHS_IN_REZ_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_DEFAULT_SEARCH_PATHS_IN_REZ_SEARCH_PATHS")
    public static let ENABLE_DEFAULT_SEARCH_PATHS_IN_SWIFT_INCLUDE_PATHS = BuiltinMacros.declareBooleanMacro("ENABLE_DEFAULT_SEARCH_PATHS_IN_SWIFT_INCLUDE_PATHS")
    public static let ENABLE_HARDENED_RUNTIME = BuiltinMacros.declareBooleanMacro("ENABLE_HARDENED_RUNTIME")
    public static let ENABLE_HEADER_DEPENDENCIES = BuiltinMacros.declareBooleanMacro("ENABLE_HEADER_DEPENDENCIES")
    public static let ENABLE_MODULE_VERIFIER = BuiltinMacros.declareBooleanMacro("ENABLE_MODULE_VERIFIER")
    public static let ENABLE_POINTER_AUTHENTICATION = BuiltinMacros.declareBooleanMacro("ENABLE_POINTER_AUTHENTICATION")
    public static let ENABLE_PROJECT_OVERRIDE_SPECS = BuiltinMacros.declareBooleanMacro("ENABLE_PROJECT_OVERRIDE_SPECS")
    public static let ENABLE_ONLY_ACTIVE_RESOURCES = BuiltinMacros.declareBooleanMacro("ENABLE_ONLY_ACTIVE_RESOURCES")
    public static let ENABLE_PLAYGROUND_RESULTS = BuiltinMacros.declareBooleanMacro("ENABLE_PLAYGROUND_RESULTS")
    public static let ENABLE_PREVIEWS = BuiltinMacros.declareBooleanMacro("ENABLE_PREVIEWS")
    public static let ENABLE_DEBUG_DYLIB = BuiltinMacros.declareBooleanMacro("ENABLE_DEBUG_DYLIB")
    public static let ENABLE_DEBUG_DYLIB_OVERRIDE = BuiltinMacros.declareBooleanMacro("ENABLE_DEBUG_DYLIB_OVERRIDE")
    public static let ENFORCE_VALID_ARCHS = BuiltinMacros.declareBooleanMacro("ENFORCE_VALID_ARCHS")
    /// Leaving this older build setting for now so existing test projects don't have to
    /// be migrated. This is merely a stop-gap measure until we can turn on the debug
    /// dylib for macOS completely.
    public static let ENABLE_PREVIEWS_DYLIB_OVERRIDE = BuiltinMacros.declareBooleanMacro("ENABLE_PREVIEWS_DYLIB_OVERRIDE")
    public static let ENABLE_SDK_IMPORTS = BuiltinMacros.declareBooleanMacro("ENABLE_SDK_IMPORTS")
    public static let ENABLE_SIGNATURE_AGGREGATION = BuiltinMacros.declareBooleanMacro("ENABLE_SIGNATURE_AGGREGATION")
    public static let DISABLE_TASK_SANDBOXING = BuiltinMacros.declareBooleanMacro("DISABLE_TASK_SANDBOXING")
    public static let ENABLE_USER_SCRIPT_SANDBOXING = BuiltinMacros.declareBooleanMacro("ENABLE_USER_SCRIPT_SANDBOXING")
    public static let ENABLE_XOJIT_PREVIEWS = BuiltinMacros.declareBooleanMacro("ENABLE_XOJIT_PREVIEWS")
    public static let EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES = BuiltinMacros.declareStringListMacro("EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES")
    public static let EXCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES = BuiltinMacros.declareStringListMacro("EXCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES")
    public static let EXCLUDED_SOURCE_FILE_NAMES = BuiltinMacros.declareStringListMacro("EXCLUDED_SOURCE_FILE_NAMES")
    public static let EXECUTABLE_FOLDER_PATH = BuiltinMacros.declarePathMacro("EXECUTABLE_FOLDER_PATH")
    public static let __ALLOW_EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES = BuiltinMacros.declareBooleanMacro("__ALLOW_EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES")
    public static let EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES = BuiltinMacros.declareStringListMacro("EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES")
    public static let EXECUTABLE_NAME = BuiltinMacros.declareStringMacro("EXECUTABLE_NAME")
    public static let EXECUTABLE_PATH = BuiltinMacros.declarePathMacro("EXECUTABLE_PATH")
    public static let __EXPORT_SDK_VARIANT_IN_SCRIPTS = BuiltinMacros.declareBooleanMacro("__EXPORT_SDK_VARIANT_IN_SCRIPTS")

    // rdar://127248825 (Pre-link the debug dylib and emit a new empty dylib that Previews can load to get in front of dyld)
    public static let EXECUTABLE_DEBUG_DYLIB_PATH = BuiltinMacros.declareStringMacro("EXECUTABLE_DEBUG_DYLIB_PATH")
    public static let EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME = BuiltinMacros.declareStringMacro("EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME")
    public static let EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME = BuiltinMacros.declareStringMacro("EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME")
    public static let EXECUTABLE_DEBUG_DYLIB_MAPPED_PLATFORM = BuiltinMacros.declareStringMacro("EXECUTABLE_DEBUG_DYLIB_MAPPED_PLATFORM")
    public static let EXECUTABLE_BLANK_INJECTION_DYLIB_PATH = BuiltinMacros.declareStringMacro("EXECUTABLE_BLANK_INJECTION_DYLIB_PATH")

    public static let EXECUTABLE_SUFFIX = BuiltinMacros.declareStringMacro("EXECUTABLE_SUFFIX")
    public static let EXECUTABLE_VARIANT_SUFFIX = BuiltinMacros.declareStringMacro("EXECUTABLE_VARIANT_SUFFIX")
    public static let EXPORTED_SYMBOLS_FILE = BuiltinMacros.declarePathMacro("EXPORTED_SYMBOLS_FILE")
    public static let EXTENSIONS_FOLDER_PATH = BuiltinMacros.declarePathMacro("EXTENSIONS_FOLDER_PATH")
    public static let FRAMEWORKS_FOLDER_PATH = BuiltinMacros.declarePathMacro("FRAMEWORKS_FOLDER_PATH")
    public static let FRAMEWORK_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("FRAMEWORK_SEARCH_PATHS")
    public static let FRAMEWORK_VERSION = BuiltinMacros.declareStringMacro("FRAMEWORK_VERSION")
    public static let FULL_PRODUCT_NAME = BuiltinMacros.declarePathMacro("FULL_PRODUCT_NAME")
    public static let FUSE_BUILD_PHASES = BuiltinMacros.declareBooleanMacro("FUSE_BUILD_PHASES")
    public static let FUSE_BUILD_SCRIPT_PHASES = BuiltinMacros.declareBooleanMacro("FUSE_BUILD_SCRIPT_PHASES")
    public static let RESCHEDULE_INDEPENDENT_HEADERS_PHASES = BuiltinMacros.declareBooleanMacro("RESCHEDULE_INDEPENDENT_HEADERS_PHASES")
    public static let GCC_C_LANGUAGE_STANDARD = BuiltinMacros.declareStringMacro("GCC_C_LANGUAGE_STANDARD")
    public static let CLANG_CXX_LANGUAGE_STANDARD = BuiltinMacros.declareStringMacro("CLANG_CXX_LANGUAGE_STANDARD")
    public static let GCC_DYNAMIC_NO_PIC = BuiltinMacros.declareBooleanMacro("GCC_DYNAMIC_NO_PIC")
    public static let GCC_ENABLE_BUILTIN_FUNCTIONS = BuiltinMacros.declareBooleanMacro("GCC_ENABLE_BUILTIN_FUNCTIONS")
    public static let GCC_ENABLE_CPP_EXCEPTIONS = BuiltinMacros.declareBooleanMacro("GCC_ENABLE_CPP_EXCEPTIONS")
    public static let GCC_ENABLE_CPP_RTTI = BuiltinMacros.declareBooleanMacro("GCC_ENABLE_CPP_RTTI")
    public static let GCC_ENABLE_KERNEL_DEVELOPMENT = BuiltinMacros.declareBooleanMacro("GCC_ENABLE_KERNEL_DEVELOPMENT")
    public static let GCC_ENABLE_PASCAL_STRINGS = BuiltinMacros.declareBooleanMacro("GCC_ENABLE_PASCAL_STRINGS")
    public static let GCC_GENERATE_DEBUGGING_SYMBOLS = BuiltinMacros.declareBooleanMacro("GCC_GENERATE_DEBUGGING_SYMBOLS")
    public static let GCC_GENERATE_PROFILING_CODE = BuiltinMacros.declareBooleanMacro("GCC_GENERATE_PROFILING_CODE")
    public static let GCC_INCREASE_PRECOMPILED_HEADER_SHARING = BuiltinMacros.declareBooleanMacro("GCC_INCREASE_PRECOMPILED_HEADER_SHARING")
    public static let GCC_INLINES_ARE_PRIVATE_EXTERN = BuiltinMacros.declareBooleanMacro("GCC_INLINES_ARE_PRIVATE_EXTERN")
    public static let GCC_INPUT_FILETYPE = BuiltinMacros.declareStringMacro("GCC_INPUT_FILETYPE")
    public static let GCC_LINK_WITH_DYNAMIC_LIBRARIES = BuiltinMacros.declareBooleanMacro("GCC_LINK_WITH_DYNAMIC_LIBRARIES")
    public static let GCC_NO_COMMON_BLOCKS = BuiltinMacros.declareBooleanMacro("GCC_NO_COMMON_BLOCKS")
    public static let GCC_OPTIMIZATION_LEVEL = BuiltinMacros.declareStringMacro("GCC_OPTIMIZATION_LEVEL")
    public static let GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS = BuiltinMacros.declareStringListMacro("GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS")
    public static let GCC_PFE_FILE_C_DIALECTS = BuiltinMacros.declareStringListMacro("GCC_PFE_FILE_C_DIALECTS")
    public static let GCC_PRECOMPILE_PREFIX_HEADER = BuiltinMacros.declareBooleanMacro("GCC_PRECOMPILE_PREFIX_HEADER")
    public static let GCC_PREFIX_HEADER = BuiltinMacros.declarePathMacro("GCC_PREFIX_HEADER")
    public static let GCC_PREPROCESSOR_DEFINITIONS = BuiltinMacros.declareStringListMacro("GCC_PREPROCESSOR_DEFINITIONS")
    public static let GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS = BuiltinMacros.declareStringListMacro("GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS")
    public static let GCC_PRODUCT_TYPE_PREPROCESSOR_DEFINITIONS = BuiltinMacros.declareStringListMacro("GCC_PRODUCT_TYPE_PREPROCESSOR_DEFINITIONS")
    public static let GCC_USE_STANDARD_INCLUDE_SEARCHING = BuiltinMacros.declareBooleanMacro("GCC_USE_STANDARD_INCLUDE_SEARCHING")
    public static let GCC_VERSION = BuiltinMacros.declareStringMacro("GCC_VERSION")
    public static let GENERATE_EMBED_IN_CODE_ACCESSORS = BuiltinMacros.declareBooleanMacro("GENERATE_EMBED_IN_CODE_ACCESSORS")
    public static let GENERATE_INFOPLIST_FILE = BuiltinMacros.declareBooleanMacro("GENERATE_INFOPLIST_FILE")
    public static let GENERATE_KERNEL_MODULE_INFO_FILE = BuiltinMacros.declareBooleanMacro("GENERATE_KERNEL_MODULE_INFO_FILE")
    public static let GENERATE_MASTER_OBJECT_FILE = BuiltinMacros.declareBooleanMacro("GENERATE_MASTER_OBJECT_FILE")
    public static let GENERATE_PKGINFO_FILE = BuiltinMacros.declareBooleanMacro("GENERATE_PKGINFO_FILE")
    public static let GENERATE_RESOURCE_ACCESSORS = BuiltinMacros.declareBooleanMacro("GENERATE_RESOURCE_ACCESSORS")
    public static let GENERATE_TEST_ENTRY_POINT = BuiltinMacros.declareBooleanMacro("GENERATE_TEST_ENTRY_POINT")
    public static let GENERATED_TEST_ENTRY_POINT_PATH = BuiltinMacros.declarePathMacro("GENERATED_TEST_ENTRY_POINT_PATH")
    public static let GENERATE_TEXT_BASED_STUBS = BuiltinMacros.declareBooleanMacro("GENERATE_TEXT_BASED_STUBS")
    public static let GENERATE_INTERMEDIATE_TEXT_BASED_STUBS = BuiltinMacros.declareBooleanMacro("GENERATE_INTERMEDIATE_TEXT_BASED_STUBS")
    public static let GLOBAL_API_NOTES_PATH = BuiltinMacros.declareStringMacro("GLOBAL_API_NOTES_PATH")
    public static let GLOBAL_CFLAGS = BuiltinMacros.declareStringListMacro("GLOBAL_CFLAGS")
    public static let HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT = BuiltinMacros.declareBooleanMacro("HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT")
    public static let HEADERMAP_USES_VFS = BuiltinMacros.declareBooleanMacro("HEADERMAP_USES_VFS")
    public static let HEADER_OUTPUT_DIR = BuiltinMacros.declareStringMacro("HEADER_OUTPUT_DIR")
    public static let HEADER_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("HEADER_SEARCH_PATHS")
    public static let IBC_REGIONS_AND_STRINGS_FILES = BuiltinMacros.declareStringListMacro("IBC_REGIONS_AND_STRINGS_FILES")
    public static let IBC_EXEC = BuiltinMacros.declarePathMacro("IBC_EXEC")
    public static let IGNORE_BUILD_PHASES = BuiltinMacros.declareBooleanMacro("IGNORE_BUILD_PHASES")
    public static let IGNORE_CREATED_BY_BUILD_SYSTEM_ATTRIBUTE_DURING_CLEAN = BuiltinMacros.declareBooleanMacro("IGNORE_CREATED_BY_BUILD_SYSTEM_ATTRIBUTE_DURING_CLEAN")
    public static let IIG_EXEC = BuiltinMacros.declarePathMacro("IIG_EXEC")
    public static let IIG_HEADERS_DIR = BuiltinMacros.declareStringMacro("IIG_HEADERS_DIR")
    public static let IMPLICIT_DEPENDENCY_DOMAIN = BuiltinMacros.declareStringMacro("IMPLICIT_DEPENDENCY_DOMAIN")
    public static let INCLUDED_EXPLICIT_TARGET_DEPENDENCIES = BuiltinMacros.declareStringListMacro("INCLUDED_EXPLICIT_TARGET_DEPENDENCIES")
    public static let INCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES = BuiltinMacros.declareStringListMacro("INCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES")
    public static let INCLUDED_SOURCE_FILE_NAMES = BuiltinMacros.declareStringListMacro("INCLUDED_SOURCE_FILE_NAMES")
    public static let INDEX_BUILD_VARIANT = BuiltinMacros.declareStringMacro("INDEX_BUILD_VARIANT")
    public static let INDEX_DIRECTORY_REMAP_VFS_FILE = BuiltinMacros.declareStringMacro("INDEX_DIRECTORY_REMAP_VFS_FILE")
    public static let INDEX_DISABLE_SCRIPT_EXECUTION = BuiltinMacros.declareBooleanMacro("INDEX_DISABLE_SCRIPT_EXECUTION")
    public static let INDEX_DISABLE_VFS_DIRECTORY_REMAP = BuiltinMacros.declareBooleanMacro("INDEX_DISABLE_VFS_DIRECTORY_REMAP")
    public static let INDEX_ENABLE_BUILD_ARENA = BuiltinMacros.declareBooleanMacro("INDEX_ENABLE_BUILD_ARENA")
    public static let INDEX_FORCE_SCRIPT_EXECUTION = BuiltinMacros.declareBooleanMacro("INDEX_FORCE_SCRIPT_EXECUTION")
    public static let INDEX_PREPARED_MODULE_CONTENT_MARKER_PATH = BuiltinMacros.declareStringMacro("INDEX_PREPARED_MODULE_CONTENT_MARKER_PATH")
    public static let INDEX_PREPARED_TARGET_MARKER_PATH = BuiltinMacros.declareStringMacro("INDEX_PREPARED_TARGET_MARKER_PATH")
    public static let INDEX_REGULAR_BUILD_PRODUCTS_DIR = BuiltinMacros.declareStringMacro("INDEX_REGULAR_BUILD_PRODUCTS_DIR")
    public static let INDEX_REGULAR_BUILD_INTERMEDIATES_DIR = BuiltinMacros.declareStringMacro("INDEX_REGULAR_BUILD_INTERMEDIATES_DIR")
    public static let INFOPLIST_ENFORCE_MINIMUM_OS = BuiltinMacros.declareBooleanMacro("INFOPLIST_ENFORCE_MINIMUM_OS")
    public static let INFOPLIST_EXPAND_BUILD_SETTINGS = BuiltinMacros.declareBooleanMacro("INFOPLIST_EXPAND_BUILD_SETTINGS")
    public static let INFOPLIST_FILE = BuiltinMacros.declarePathMacro("INFOPLIST_FILE")
    public static let INFOPLIST_FILE_CONTENTS = BuiltinMacros.declareStringMacro("INFOPLIST_FILE_CONTENTS")
    public static let INFOPLIST_OTHER_PREPROCESSOR_FLAGS = BuiltinMacros.declareStringListMacro("INFOPLIST_OTHER_PREPROCESSOR_FLAGS")
    public static let INFOPLIST_OUTPUT_FORMAT = BuiltinMacros.declareStringMacro("INFOPLIST_OUTPUT_FORMAT")
    public static let INFOPLIST_PATH = BuiltinMacros.declarePathMacro("INFOPLIST_PATH")
    public static let INFOPLIST_PREFIX_HEADER = BuiltinMacros.declareStringMacro("INFOPLIST_PREFIX_HEADER")
    public static let INFOPLIST_PREPROCESS = BuiltinMacros.declareBooleanMacro("INFOPLIST_PREPROCESS")
    public static let INFOPLIST_PREPROCESSOR_DEFINITIONS = BuiltinMacros.declareStringListMacro("INFOPLIST_PREPROCESSOR_DEFINITIONS")
    public static let INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE = BuiltinMacros.declareBooleanMacro("INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE")
    public static let INLINE_PRIVATE_FRAMEWORKS = BuiltinMacros.declareBooleanMacro("INLINE_PRIVATE_FRAMEWORKS")
    public static let INPUT_FILE_BASE = BuiltinMacros.declareStringMacro("INPUT_FILE_BASE")
    public static let INPUT_FILE_DIR = BuiltinMacros.declareStringMacro("INPUT_FILE_DIR")
    public static let INPUT_FILE_NAME = BuiltinMacros.declareStringMacro("INPUT_FILE_NAME")
    public static let INPUT_FILE_PATH = BuiltinMacros.declareStringMacro("INPUT_FILE_PATH")
    public static let INPUT_FILE_REGION_PATH_COMPONENT = BuiltinMacros.declareStringMacro("INPUT_FILE_REGION_PATH_COMPONENT")
    public static let INPUT_FILE_SUFFIX = BuiltinMacros.declareStringMacro("INPUT_FILE_SUFFIX")
    public static let INSTALLHDRS_COPY_PHASE = BuiltinMacros.declareBooleanMacro("INSTALLHDRS_COPY_PHASE")
    public static let INSTALLHDRS_SCRIPT_PHASE = BuiltinMacros.declareBooleanMacro("INSTALLHDRS_SCRIPT_PHASE")
    public static let INSTALLLOC_LANGUAGE = BuiltinMacros.declareStringListMacro("INSTALLLOC_LANGUAGE")
    public static let INSTALLLOC_SCRIPT_PHASE = BuiltinMacros.declareBooleanMacro("INSTALLLOC_SCRIPT_PHASE")
    public static let INSTALL_DIR = BuiltinMacros.declarePathMacro("INSTALL_DIR")
    public static let INSTALL_GROUP = BuiltinMacros.declareStringMacro("INSTALL_GROUP")
    public static let INSTALL_MODE_FLAG = BuiltinMacros.declareStringMacro("INSTALL_MODE_FLAG")
    public static let INSTALL_OWNER = BuiltinMacros.declareStringMacro("INSTALL_OWNER")
    public static let INSTRUMENTS_PACKAGE_BUILDER_DEPENDENCY_INFO_FILE = BuiltinMacros.declarePathMacro("INSTRUMENTS_PACKAGE_BUILDER_DEPENDENCY_INFO_FILE")
    public static let INTENTS_CODEGEN_LANGUAGE = BuiltinMacros.declareStringMacro("INTENTS_CODEGEN_LANGUAGE")
    public static let IS_MACCATALYST = BuiltinMacros.declareBooleanMacro("IS_MACCATALYST")
    public static let IS_UNOPTIMIZED_BUILD = BuiltinMacros.declareBooleanMacro("IS_UNOPTIMIZED_BUILD")
    public static let IS_ZIPPERED = BuiltinMacros.declareBooleanMacro("IS_ZIPPERED")
    public static let InputFile = BuiltinMacros.declareStringMacro("InputFile")
    public static let InputFileAbsolutePath = BuiltinMacros.declareStringMacro("InputFileAbsolutePath")
    public static let InputFileBase = BuiltinMacros.declareStringMacro("InputFileBase")
    public static let InputFileDir = BuiltinMacros.declareStringMacro("InputFileDir")
    public static let InputFileName = BuiltinMacros.declareStringMacro("InputFileName")
    public static let InputFilePath = BuiltinMacros.declareStringMacro("InputFilePath")
    public static let InputFileRegionPathComponent = BuiltinMacros.declareStringMacro("InputFileRegionPathComponent")
    public static let InputFileRelativePath = BuiltinMacros.declareStringMacro("InputFileRelativePath")
    public static let InputFileSuffix = BuiltinMacros.declareStringMacro("InputFileSuffix")
    public static let InputFileTextEncoding = BuiltinMacros.declareStringMacro("InputFileTextEncoding")
    public static let InputPath = BuiltinMacros.declareStringMacro("InputPath")
    public static let JAVA_ARCHIVE_CLASSES = BuiltinMacros.declareBooleanMacro("JAVA_ARCHIVE_CLASSES")
    public static let JAVA_FOLDER_PATH = BuiltinMacros.declarePathMacro("JAVA_FOLDER_PATH")
    public static let KEEP_PRIVATE_EXTERNS = BuiltinMacros.declareBooleanMacro("KEEP_PRIVATE_EXTERNS")
    public static let KERNEL_EXTENSION_HEADER_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("KERNEL_EXTENSION_HEADER_SEARCH_PATHS")
    public static let KERNEL_FRAMEWORK = BuiltinMacros.declarePathMacro("KERNEL_FRAMEWORK_HEADERS")
    public static let KERNEL_FRAMEWORK_HEADERS = BuiltinMacros.declarePathMacro("KERNEL_FRAMEWORK_HEADERS")
    public static let __KNOWN_SPI_INSTALL_PATHS = BuiltinMacros.declareStringListMacro("__KNOWN_SPI_INSTALL_PATHS")
    public static let LD = BuiltinMacros.declareStringMacro("LD")
    public static let LDPLUSPLUS = BuiltinMacros.declareStringMacro("LDPLUSPLUS")
    public static let LD_CLIENT_NAME = BuiltinMacros.declareStringMacro("LD_CLIENT_NAME")
    public static let LD_DEPENDENCY_INFO_FILE = BuiltinMacros.declarePathMacro("LD_DEPENDENCY_INFO_FILE")
    public static let LD_DYLIB_INSTALL_NAME = BuiltinMacros.declareStringMacro("LD_DYLIB_INSTALL_NAME")
    public static let LD_ENTRY_POINT = BuiltinMacros.declareStringMacro("LD_ENTRY_POINT")
    public static let LD_EXPORT_GLOBAL_SYMBOLS = BuiltinMacros.declareBooleanMacro("LD_EXPORT_GLOBAL_SYMBOLS")
    public static let LD_LTO_OBJECT_FILE = BuiltinMacros.declarePathMacro("LD_LTO_OBJECT_FILE")
    public static let LD_NO_PIE = BuiltinMacros.declareBooleanMacro("LD_NO_PIE")
    public static let LD_RUNPATH_SEARCH_PATHS = BuiltinMacros.declareStringListMacro("LD_RUNPATH_SEARCH_PATHS")
    public static let LD_SDK_IMPORTS_FILE = BuiltinMacros.declarePathMacro("LD_SDK_IMPORTS_FILE")
    public static let LD_WARN_UNUSED_DYLIBS = BuiltinMacros.declareBooleanMacro("LD_WARN_UNUSED_DYLIBS")
    public static let _LD_MULTIARCH = BuiltinMacros.declareBooleanMacro("_LD_MULTIARCH")
    public static let _LD_MULTIARCH_PREFIX_MAP = BuiltinMacros.declareStringListMacro("_LD_MULTIARCH_PREFIX_MAP")
    public static let LEX = BuiltinMacros.declarePathMacro("LEX")
    public static let LEXFLAGS = BuiltinMacros.declareStringListMacro("LEXFLAGS")
    public static let LIBRARIAN = BuiltinMacros.declareStringMacro("LIBRARIAN")
    public static let LIBRARY_FLAG_NOSPACE = BuiltinMacros.declareBooleanMacro("LIBRARY_FLAG_NOSPACE")
    public static let LIBRARY_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("LIBRARY_SEARCH_PATHS")
    public static let LIBTOOL = BuiltinMacros.declarePathMacro("LIBTOOL")
    public static let LIBTOOL_DEPENDENCY_INFO_FILE = BuiltinMacros.declarePathMacro("LIBTOOL_DEPENDENCY_INFO_FILE")
    public static let LIBTOOL_USE_RESPONSE_FILE = BuiltinMacros.declareBooleanMacro("LIBTOOL_USE_RESPONSE_FILE")
    public static let LINKER = BuiltinMacros.declareStringMacro("LINKER")
    public static let LINKER_DRIVER = BuiltinMacros.declareEnumMacro("LINKER_DRIVER") as EnumMacroDeclaration<LinkerDriverChoice>
    public static let ALTERNATE_LINKER = BuiltinMacros.declareStringMacro("ALTERNATE_LINKER")
    public static let LINK_OBJC_RUNTIME = BuiltinMacros.declareBooleanMacro("LINK_OBJC_RUNTIME")
    public static let LINK_WITH_STANDARD_LIBRARIES = BuiltinMacros.declareBooleanMacro("LINK_WITH_STANDARD_LIBRARIES")
    public static let LIPO = BuiltinMacros.declareStringMacro("LIPO")
    public static let LLVM_TARGET_TRIPLE_SUFFIX = BuiltinMacros.declareStringMacro("LLVM_TARGET_TRIPLE_SUFFIX")
    public static let LM_AUX_CONST_METADATA_LIST_PATH = BuiltinMacros.declarePathMacro("LM_AUX_CONST_METADATA_LIST_PATH")
    public static let LM_AUX_INTENTS_METADATA_FILES_LIST_PATH = BuiltinMacros.declarePathMacro("LM_AUX_INTENTS_METADATA_FILES_LIST_PATH")
    public static let LM_AUX_INTENTS_STATIC_METADATA_FILES_LIST_PATH = BuiltinMacros.declarePathMacro("LM_AUX_INTENTS_STATIC_METADATA_FILES_LIST_PATH")
    public static let LM_BINARY_PATH = BuiltinMacros.declareStringMacro("LM_BINARY_PATH")
    public static let LM_FORCE_LINK_GENERATION = BuiltinMacros.declareBooleanMacro("LM_FORCE_LINK_GENERATION")
    public static let LM_COMPILE_TIME_EXTRACTION = BuiltinMacros.declareBooleanMacro("LM_COMPILE_TIME_EXTRACTION")
    public static let LM_DEPENDENCY_FILES = BuiltinMacros.declareStringListMacro("LM_DEPENDENCY_FILES")
    public static let LM_FORCE_METADATA_OUTPUT = BuiltinMacros.declareBooleanMacro("LM_FORCE_METADATA_OUTPUT")
    public static let LM_OUTPUT_DIR = BuiltinMacros.declareStringMacro("LM_OUTPUT_DIR")
    public static let LM_SKIP_METADATA_EXTRACTION = BuiltinMacros.declareBooleanMacro("LM_SKIP_METADATA_EXTRACTION")
    public static let LM_SOURCE_FILE_LIST_PATH = BuiltinMacros.declareStringListMacro("LM_SOURCE_FILE_LIST_PATH")
    public static let LM_INTENTS_METADATA_FILES_LIST_PATH = BuiltinMacros.declareStringListMacro("LM_INTENTS_METADATA_FILES_LIST_PATH")
    public static let LM_INTENTS_STATIC_METADATA_FILES_LIST_PATH = BuiltinMacros.declareStringListMacro("LM_INTENTS_STATIC_METADATA_FILES_LIST_PATH")
    public static let LM_STRINGSDATA_FILES = BuiltinMacros.declareStringListMacro("LM_STRINGSDATA_FILES")
    public static let LM_STRINGS_FILE_PATH_LIST = BuiltinMacros.declareStringListMacro("LM_STRINGS_FILE_PATH_LIST")
    public static let LM_SWIFT_CONST_VALS_LIST_PATH = BuiltinMacros.declareStringListMacro("LM_SWIFT_CONST_VALS_LIST_PATH")
    public static let LM_NO_APP_SHORTCUT_LOCALIZATION = BuiltinMacros.declareBooleanMacro("LM_NO_APP_SHORTCUT_LOCALIZATION")
    public static let LOCALIZATION_EXPORT_SUPPORTED = BuiltinMacros.declareBooleanMacro("LOCALIZATION_EXPORT_SUPPORTED")
    public static let LOCALIZATION_PREFERS_STRING_CATALOGS = BuiltinMacros.declareBooleanMacro("LOCALIZATION_PREFERS_STRING_CATALOGS")
    public static let MACH_O_TYPE = BuiltinMacros.declareStringMacro("MACH_O_TYPE")
    public static let MACOS_CREATOR = BuiltinMacros.declareStringMacro("MACOS_CREATOR")
    public static let MACOS_CREATOR_ARG = BuiltinMacros.declareStringMacro("MACOS_CREATOR_ARG")
    public static let MACOS_TYPE = BuiltinMacros.declareStringMacro("MACOS_TYPE")
    public static let MACOS_TYPE_ARG = BuiltinMacros.declareStringMacro("MACOS_TYPE_ARG")
    public static let MARKETING_VERSION = BuiltinMacros.declareStringMacro("MARKETING_VERSION")
    public static let MESSAGES_APPLICATION_SUPPORT_FOLDER_PATH = BuiltinMacros.declareStringMacro("MESSAGES_APPLICATION_SUPPORT_FOLDER_PATH")
    public static let MESSAGES_APPLICATION_EXTENSION_SUPPORT_FOLDER_PATH = BuiltinMacros.declareStringMacro("MESSAGES_APPLICATION_EXTENSION_SUPPORT_FOLDER_PATH")
    public static let MESSAGES_APPLICATION_PRODUCT_BINARY_SOURCE_PATH = BuiltinMacros.declareStringMacro("MESSAGES_APPLICATION_PRODUCT_BINARY_SOURCE_PATH")
    public static let MESSAGES_APPLICATION_EXTENSION_PRODUCT_BINARY_SOURCE_PATH = BuiltinMacros.declareStringMacro("MESSAGES_APPLICATION_EXTENSION_PRODUCT_BINARY_SOURCE_PATH")
    public static let MIG_EXEC = BuiltinMacros.declarePathMacro("MIG_EXEC")
    public static let MLKIT_CODEGEN_LANGUAGE = BuiltinMacros.declareStringMacro("MLKIT_CODEGEN_LANGUAGE")
    public static let MLKIT_CODEGEN_SWIFT_VERSION = BuiltinMacros.declareStringMacro("MLKIT_CODEGEN_SWIFT_VERSION")
    public static let MODULEMAP_FILE = BuiltinMacros.declareStringMacro("MODULEMAP_FILE")
    public static let MODULEMAP_FILE_CONTENTS = BuiltinMacros.declareStringMacro("MODULEMAP_FILE_CONTENTS")
    public static let MODULEMAP_PATH = BuiltinMacros.declareStringMacro("MODULEMAP_PATH")
    public static let MODULEMAP_PRIVATE_FILE = BuiltinMacros.declareStringMacro("MODULEMAP_PRIVATE_FILE")
    public static let MODULES_FOLDER_PATH = BuiltinMacros.declarePathMacro("MODULES_FOLDER_PATH")
    public static let MODULE_VERIFIER_KIND = BuiltinMacros.declareEnumMacro("MODULE_VERIFIER_KIND") as EnumMacroDeclaration<ModuleVerifierKind>
    public static let MODULE_VERIFIER_LSV = BuiltinMacros.declareBooleanMacro("MODULE_VERIFIER_LSV")
    public static let MODULE_VERIFIER_SUPPORTED_LANGUAGES = BuiltinMacros.declareStringListMacro("MODULE_VERIFIER_SUPPORTED_LANGUAGES")
    public static let MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS = BuiltinMacros.declareStringListMacro("MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS")
    public static let MODULE_VERIFIER_TARGET_TRIPLE_ARCHS = BuiltinMacros.declareStringListMacro("MODULE_VERIFIER_TARGET_TRIPLE_ARCHS")
    public static let MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS = BuiltinMacros.declareStringListMacro("MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS")
    public static let MTLCOMPILER_DEPENDENCY_INFO_FILE = BuiltinMacros.declareStringMacro("MTLCOMPILER_DEPENDENCY_INFO_FILE")
    public static let OBJCC = BuiltinMacros.declarePathMacro("OBJCC")
    public static let OBJCPLUSPLUS = BuiltinMacros.declarePathMacro("OBJCPLUSPLUS")
    public static let OBJECT_FILE_DIR = BuiltinMacros.declarePathMacro("OBJECT_FILE_DIR")
    public static let _OBSOLETE_MANUAL_BUILD_ORDER = BuiltinMacros.declareBooleanMacro("_OBSOLETE_MANUAL_BUILD_ORDER")
    public static let ONLY_ACTIVE_ARCH = BuiltinMacros.declareBooleanMacro("ONLY_ACTIVE_ARCH")
    public static let OPENCLC = BuiltinMacros.declareStringMacro("OPENCLC")
    public static let OPENCL_ARCHS = BuiltinMacros.declareStringListMacro("OPENCL_ARCHS")
    public static let OPENCL_AUTO_VECTORIZE_ENABLE = BuiltinMacros.declareBooleanMacro("OPENCL_AUTO_VECTORIZE_ENABLE")
    public static let OPENCL_COMPILER_VERSION = BuiltinMacros.declareStringMacro("OPENCL_COMPILER_VERSION")
    public static let OPENCL_DENORMS_ARE_ZERO = BuiltinMacros.declareBooleanMacro("OPENCL_DENORMS_ARE_ZERO")
    public static let OPENCL_DOUBLE_AS_SINGLE = BuiltinMacros.declareBooleanMacro("OPENCL_DOUBLE_AS_SINGLE")
    public static let OPENCL_FAST_RELAXED_MATH = BuiltinMacros.declareBooleanMacro("OPENCL_FAST_RELAXED_MATH")
    public static let OPENCL_MAD_ENABLE = BuiltinMacros.declareBooleanMacro("OPENCL_MAD_ENABLE")
    public static let OPENCL_OPTIMIZATION_LEVEL = BuiltinMacros.declareStringMacro("OPENCL_OPTIMIZATION_LEVEL")
    public static let OPENCL_OTHER_BC_FLAGS = BuiltinMacros.declareStringListMacro("OPENCL_OTHER_BC_FLAGS")
    public static let OPENCL_PREPROCESSOR_DEFINITIONS = BuiltinMacros.declareStringListMacro("OPENCL_PREPROCESSOR_DEFINITIONS")
    public static let OPTIMIZATION_CFLAGS = BuiltinMacros.declareStringListMacro("OPTIMIZATION_CFLAGS")
    public static let ORDER_FILE = BuiltinMacros.declarePathMacro("ORDER_FILE")
    public static let OTHER_CFLAGS = BuiltinMacros.declareStringListMacro("OTHER_CFLAGS")
    public static let OTHER_CODE_SIGN_FLAGS = BuiltinMacros.declareStringListMacro("OTHER_CODE_SIGN_FLAGS")
    public static let OTHER_CPLUSPLUSFLAGS = BuiltinMacros.declareStringListMacro("OTHER_CPLUSPLUSFLAGS")
    public static let OTHER_DOCC_FLAGS = BuiltinMacros.declareStringListMacro("OTHER_DOCC_FLAGS")
    public static let OTHER_LDFLAGS = BuiltinMacros.declareStringListMacro("OTHER_LDFLAGS")
    public static let OTHER_LIPOFLAGS = BuiltinMacros.declareStringListMacro("OTHER_LIPOFLAGS")
    public static let OTHER_MIGFLAGS = BuiltinMacros.declareStringListMacro("OTHER_MIGFLAGS")
    public static let OTHER_MODULE_VERIFIER_FLAGS = BuiltinMacros.declareStringListMacro("OTHER_MODULE_VERIFIER_FLAGS")
    public static let OTHER_PRECOMP_CFLAGS = BuiltinMacros.declareStringListMacro("OTHER_PRECOMP_CFLAGS")
    public static let OTHER_RESMERGERFLAGS = BuiltinMacros.declareStringListMacro("OTHER_RESMERGERFLAGS")
    public static let OTHER_REZFLAGS = BuiltinMacros.declareStringListMacro("OTHER_REZFLAGS")
    public static let OTHER_SWIFT_FLAGS = BuiltinMacros.declareStringListMacro("OTHER_SWIFT_FLAGS")
    public static let PACKAGE_BUILD_DYNAMICALLY = BuiltinMacros.declareBooleanMacro("PACKAGE_BUILD_DYNAMICALLY")
    public static let PACKAGE_SKIP_AUTO_EMBEDDING_DYNAMIC_BINARY_FRAMEWORKS = BuiltinMacros.declareBooleanMacro("PACKAGE_SKIP_AUTO_EMBEDDING_DYNAMIC_BINARY_FRAMEWORKS")
    public static let PACKAGE_SKIP_AUTO_EMBEDDING_STATIC_BINARY_FRAMEWORKS = BuiltinMacros.declareBooleanMacro("PACKAGE_SKIP_AUTO_EMBEDDING_STATIC_BINARY_FRAMEWORKS")
    public static let PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME = BuiltinMacros.declareBooleanMacro("PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME")
    public static let PATH = BuiltinMacros.declareStringMacro("PATH")
    public static let PBXCP_EXCLUDE_SUBPATHS = BuiltinMacros.declareStringListMacro("PBXCP_EXCLUDE_SUBPATHS")
    public static let PBXCP_INCLUDE_ONLY_SUBPATHS = BuiltinMacros.declareStringListMacro("PBXCP_INCLUDE_ONLY_SUBPATHS")
    public static let PBXCP_STRIP_BITCODE = BuiltinMacros.declareBooleanMacro("PBXCP_STRIP_BITCODE")
    public static let PBXCP_STRIP_SUBPATHS = BuiltinMacros.declareStringListMacro("PBXCP_STRIP_SUBPATHS")
    public static let PBXCP_STRIP_UNSIGNED_BINARIES = BuiltinMacros.declareBooleanMacro("PBXCP_STRIP_UNSIGNED_BINARIES")
    public static let PBXCP_BITCODE_STRIP_MODE = BuiltinMacros.declareStringMacro("PBXCP_BITCODE_STRIP_MODE")
    public static let PBXCP_BITCODE_STRIP_TOOL = BuiltinMacros.declarePathMacro("PBXCP_BITCODE_STRIP_TOOL")
    public static let PER_ARCH_CFLAGS = BuiltinMacros.declareStringListMacro("PER_ARCH_CFLAGS")
    public static let PER_ARCH_LD = BuiltinMacros.declareStringMacro("PER_ARCH_LD")
    public static let PER_ARCH_LDPLUSPLUS = BuiltinMacros.declareStringMacro("PER_ARCH_LDPLUSPLUS")
    public static let PER_ARCH_MODULE_FILE_DIR = BuiltinMacros.declarePathMacro("PER_ARCH_MODULE_FILE_DIR")
    public static let PER_ARCH_OBJECT_FILE_DIR = BuiltinMacros.declarePathMacro("PER_ARCH_OBJECT_FILE_DIR")
    public static let PER_VARIANT_CFLAGS = BuiltinMacros.declareStringListMacro("PER_VARIANT_CFLAGS")
    public static let PER_VARIANT_OBJECT_FILE_DIR = BuiltinMacros.declareStringMacro("PER_VARIANT_OBJECT_FILE_DIR")
    public static let PER_VARIANT_OTHER_LIPOFLAGS = BuiltinMacros.declareStringListMacro("PER_VARIANT_OTHER_LIPOFLAGS")
    public static let PKGINFO_PATH = BuiltinMacros.declarePathMacro("PKGINFO_PATH")
    public static let PLIST_FILE_OUTPUT_FORMAT = BuiltinMacros.declareStringMacro("PLIST_FILE_OUTPUT_FORMAT")
    public static let PLUGINS_FOLDER_PATH = BuiltinMacros.declarePathMacro("PLUGINS_FOLDER_PATH")
    public static let __POPULATE_COMPATIBILITY_ARCH_MAP = BuiltinMacros.declareBooleanMacro("__POPULATE_COMPATIBILITY_ARCH_MAP")
    public static let PRELINK_FLAGS = BuiltinMacros.declareStringListMacro("PRELINK_FLAGS")
    public static let PRELINK_LIBS = BuiltinMacros.declareStringListMacro("PRELINK_LIBS")
    public static let PRIVATE_HEADERS_FOLDER_PATH = BuiltinMacros.declarePathMacro("PRIVATE_HEADERS_FOLDER_PATH")
    public static let PROCESSED_INFOPLIST_PATH = BuiltinMacros.declarePathMacro("PROCESSED_INFOPLIST_PATH")
    public static let PRODUCT_BINARY_SOURCE_PATH = BuiltinMacros.declareStringMacro("PRODUCT_BINARY_SOURCE_PATH")
    public static let PRODUCT_BUNDLE_IDENTIFIER = BuiltinMacros.declareStringMacro("PRODUCT_BUNDLE_IDENTIFIER")
    public static let PRODUCT_BUNDLE_PACKAGE_TYPE = BuiltinMacros.declareStringMacro("PRODUCT_BUNDLE_PACKAGE_TYPE")
    public static let PRODUCT_DEFINITION_PLIST = BuiltinMacros.declareStringMacro("PRODUCT_DEFINITION_PLIST")
    public static let PRODUCT_MODULE_NAME = BuiltinMacros.declareStringMacro("PRODUCT_MODULE_NAME")
    public static let PRODUCT_SPECIFIC_LDFLAGS = BuiltinMacros.declareStringListMacro("PRODUCT_SPECIFIC_LDFLAGS") // FIXME: We shouldn't need to declare this, but it is a workaround for an instance of: <rdar://problem/24343554> [Swift Build] Unable to find XCTest module
    public static let PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS")
    public static let PRODUCT_TYPE_HEADER_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("PRODUCT_TYPE_HEADER_SEARCH_PATHS")
    public static let PRODUCT_TYPE_LIBRARY_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("PRODUCT_TYPE_LIBRARY_SEARCH_PATHS")
    public static let PRODUCT_TYPE_SWIFT_INCLUDE_PATHS = BuiltinMacros.declarePathListMacro("PRODUCT_TYPE_SWIFT_INCLUDE_PATHS")
    public static let PRODUCT_TYPE_SWIFT_STDLIB_TOOL_FLAGS = BuiltinMacros.declareStringListMacro("PRODUCT_TYPE_SWIFT_STDLIB_TOOL_FLAGS")
    public static let PRODUCT_TYPE_HAS_STUB_BINARY = BuiltinMacros.declareBooleanMacro("PRODUCT_TYPE_HAS_STUB_BINARY")
    public static let PROVISIONING_PROFILE = BuiltinMacros.declareStringMacro("PROVISIONING_PROFILE")
    public static let PROVISIONING_PROFILE_DESTINATION_PATH = BuiltinMacros.declareStringMacro("PROVISIONING_PROFILE_DESTINATION_PATH")
    public static let PROVISIONING_PROFILE_REQUIRED = BuiltinMacros.declareBooleanMacro("PROVISIONING_PROFILE_REQUIRED")
    public static let PROVISIONING_PROFILE_SPECIFIER = BuiltinMacros.declareStringMacro("PROVISIONING_PROFILE_SPECIFIER")
    public static let PROVISIONING_PROFILE_SUPPORTED = BuiltinMacros.declareBooleanMacro("PROVISIONING_PROFILE_SUPPORTED")
    public static let PUBLIC_HEADERS_FOLDER_PATH = BuiltinMacros.declarePathMacro("PUBLIC_HEADERS_FOLDER_PATH")
    public static let ProductResourcesDir = BuiltinMacros.declareStringMacro("ProductResourcesDir")
    public static let RECORD_SYSTEM_HEADER_DEPENDENCIES_OUTSIDE_SYSROOT = BuiltinMacros.declareBooleanMacro("RECORD_SYSTEM_HEADER_DEPENDENCIES_OUTSIDE_SYSROOT")
    public static let RECURSIVE_SEARCH_PATHS_FOLLOW_SYMLINKS = BuiltinMacros.declareBooleanMacro("RECURSIVE_SEARCH_PATHS_FOLLOW_SYMLINKS")
    public static let REEXPORTED_LIBRARY_NAMES = BuiltinMacros.declareStringListMacro("REEXPORTED_LIBRARY_NAMES")
    public static let REEXPORTED_LIBRARY_PATHS = BuiltinMacros.declarePathListMacro("REEXPORTED_LIBRARY_PATHS")
    public static let REEXPORTED_FRAMEWORK_NAMES = BuiltinMacros.declareStringListMacro("REEXPORTED_FRAMEWORK_NAMES")
    public static let REMOVE_CVS_FROM_RESOURCES = BuiltinMacros.declareBooleanMacro("REMOVE_CVS_FROM_RESOURCES")
    public static let REMOVE_GIT_FROM_RESOURCES = BuiltinMacros.declareBooleanMacro("REMOVE_GIT_FROM_RESOURCES")
    public static let REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES = BuiltinMacros.declareBooleanMacro("REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES")
    public static let REMOVE_STATIC_EXECUTABLES_FROM_EMBEDDED_BUNDLES = BuiltinMacros.declareBooleanMacro("REMOVE_STATIC_EXECUTABLES_FROM_EMBEDDED_BUNDLES")
    public static let REMOVE_HG_FROM_RESOURCES = BuiltinMacros.declareBooleanMacro("REMOVE_HG_FROM_RESOURCES")
    public static let REMOVE_SVN_FROM_RESOURCES = BuiltinMacros.declareBooleanMacro("REMOVE_SVN_FROM_RESOURCES")
    public static let RESMERGER_SOURCES_FORK = BuiltinMacros.declareStringMacro("RESMERGER_SOURCES_FORK")
    public static let RESOURCES_PLATFORM_NAME = BuiltinMacros.declareStringMacro("RESOURCES_PLATFORM_NAME")
    public static let RESOURCES_MINIMUM_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("RESOURCES_MINIMUM_DEPLOYMENT_TARGET")
    public static let RESOURCES_TARGETED_DEVICE_FAMILY = BuiltinMacros.declareStringListMacro("RESOURCES_TARGETED_DEVICE_FAMILY")
    public static let RESOURCE_FLAG = BuiltinMacros.declareBooleanMacro("RESOURCE_FLAG")
    public static let REZ_COLLECTOR_DIR = BuiltinMacros.declarePathMacro("REZ_COLLECTOR_DIR")
    public static let REZ_NO_AUTOMATIC_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("REZ_NO_AUTOMATIC_SEARCH_PATHS")
    public static let REZ_OBJECTS_DIR = BuiltinMacros.declarePathMacro("REZ_OBJECTS_DIR")
    public static let REZ_PREFIX_FILE = BuiltinMacros.declarePathMacro("REZ_PREFIX_FILE")
    public static let REZ_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("REZ_SEARCH_PATHS")
    public static let RUN_CLANG_STATIC_ANALYZER = BuiltinMacros.declareBooleanMacro("RUN_CLANG_STATIC_ANALYZER")
    public static let RUN_SWIFT_ABI_CHECKER_TOOL = BuiltinMacros.declareBooleanMacro("RUN_SWIFT_ABI_CHECKER_TOOL")
    public static let RUN_SWIFT_ABI_CHECKER_TOOL_DRIVER = BuiltinMacros.declareBooleanMacro("RUN_SWIFT_ABI_CHECKER_TOOL_DRIVER")
    public static let RUN_SWIFT_ABI_GENERATION_TOOL = BuiltinMacros.declareBooleanMacro("RUN_SWIFT_ABI_GENERATION_TOOL")
    public static let SCRIPTS_FOLDER_PATH = BuiltinMacros.declarePathMacro("SCRIPTS_FOLDER_PATH")
    public static let SEPARATE_STRIP = BuiltinMacros.declareBooleanMacro("SEPARATE_STRIP")
    public static let SHALLOW_BUNDLE = BuiltinMacros.declareBooleanMacro("SHALLOW_BUNDLE")
    public static let SHARED_FRAMEWORKS_FOLDER_PATH = BuiltinMacros.declarePathMacro("SHARED_FRAMEWORKS_FOLDER_PATH")
    public static let SHARED_SUPPORT_FOLDER_PATH = BuiltinMacros.declarePathMacro("SHARED_SUPPORT_FOLDER_PATH")
    public static let STRINGS_FILE_INPUT_ENCODING = BuiltinMacros.declareStringMacro("STRINGS_FILE_INPUT_ENCODING")
    public static let STRINGS_FILE_OUTPUT_ENCODING = BuiltinMacros.declareStringMacro("STRINGS_FILE_OUTPUT_ENCODING")
    public static let STRINGS_FILE_OUTPUT_FILENAME = BuiltinMacros.declareStringMacro("STRINGS_FILE_OUTPUT_FILENAME")
    public static let STRINGS_FILE_INFOPLIST_RENAME = BuiltinMacros.declareBooleanMacro("STRINGS_FILE_INFOPLIST_RENAME")
    public static let SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = BuiltinMacros.declareBooleanMacro("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD")
    public static let SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = BuiltinMacros.declareBooleanMacro("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD")
    public static let SUPPORTS_TEXT_BASED_API = BuiltinMacros.declareBooleanMacro("SUPPORTS_TEXT_BASED_API")
    public static let SWIFT_AUTOLINK_EXTRACT_OUTPUT_PATH = BuiltinMacros.declarePathMacro("SWIFT_AUTOLINK_EXTRACT_OUTPUT_PATH")
    public static let PLATFORM_REQUIRES_SWIFT_AUTOLINK_EXTRACT = BuiltinMacros.declareBooleanMacro("PLATFORM_REQUIRES_SWIFT_AUTOLINK_EXTRACT")
    public static let PLATFORM_REQUIRES_SWIFT_MODULEWRAP = BuiltinMacros.declareBooleanMacro("PLATFORM_REQUIRES_SWIFT_MODULEWRAP")
    public static let SWIFT_ABI_CHECKER_BASELINE_DIR = BuiltinMacros.declareStringMacro("SWIFT_ABI_CHECKER_BASELINE_DIR")
    public static let SWIFT_ABI_CHECKER_EXCEPTIONS_FILE = BuiltinMacros.declareStringMacro("SWIFT_ABI_CHECKER_EXCEPTIONS_FILE")
    public static let SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR = BuiltinMacros.declareStringMacro("SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR")
    public static let SWIFT_ACCESS_NOTES_PATH = BuiltinMacros.declareStringMacro("SWIFT_ACCESS_NOTES_PATH")
    public static let SWIFT_ALLOW_INSTALL_OBJC_HEADER = BuiltinMacros.declareBooleanMacro("SWIFT_ALLOW_INSTALL_OBJC_HEADER")
    public static let __SWIFT_ALLOW_INSTALL_OBJC_HEADER_MESSAGE = BuiltinMacros.declareStringMacro("__SWIFT_ALLOW_INSTALL_OBJC_HEADER_MESSAGE")
    public static let SWIFT_COMPILATION_MODE = BuiltinMacros.declareStringMacro("SWIFT_COMPILATION_MODE")
    public static let SWIFT_DEPENDENCY_REGISTRATION_MODE = BuiltinMacros.declareEnumMacro("SWIFT_DEPENDENCY_REGISTRATION_MODE") as EnumMacroDeclaration<SwiftDependencyRegistrationMode>
    public static let SWIFT_DEPLOYMENT_TARGET = BuiltinMacros.declareStringMacro("SWIFT_DEPLOYMENT_TARGET")
    public static let SWIFT_DEVELOPMENT_TOOLCHAIN = BuiltinMacros.declareBooleanMacro("SWIFT_DEVELOPMENT_TOOLCHAIN")
    public static let SWIFT_EMIT_LOC_STRINGS = BuiltinMacros.declareBooleanMacro("SWIFT_EMIT_LOC_STRINGS")
    public static let SWIFT_EMIT_MODULE_INTERFACE = BuiltinMacros.declareBooleanMacro("SWIFT_EMIT_MODULE_INTERFACE")
    public static let SWIFT_ENABLE_BATCH_MODE = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_BATCH_MODE")
    public static let SWIFT_ENABLE_INCREMENTAL_COMPILATION = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_INCREMENTAL_COMPILATION")
    public static let SWIFT_ENABLE_LAYOUT_STRING_VALUE_WITNESSES = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_LAYOUT_STRING_VALUE_WITNESSES")
    public static let SWIFT_ENABLE_LIBRARY_EVOLUTION = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_LIBRARY_EVOLUTION")
    public static let SWIFT_ENABLE_BARE_SLASH_REGEX = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_BARE_SLASH_REGEX")
    public static let SWIFT_ENABLE_EMIT_CONST_VALUES = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_EMIT_CONST_VALUES")
    public static let SWIFT_ENABLE_OPAQUE_TYPE_ERASURE = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_OPAQUE_TYPE_ERASURE")
    public static let SWIFT_EMIT_CONST_VALUE_PROTOCOLS = BuiltinMacros.declareStringListMacro("SWIFT_EMIT_CONST_VALUE_PROTOCOLS")
    public static let SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS = BuiltinMacros.declareBooleanMacro("SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS")
    public static let SWIFT_USE_INTEGRATED_DRIVER = BuiltinMacros.declareBooleanMacro("SWIFT_USE_INTEGRATED_DRIVER")
    public static let SWIFT_EAGER_MODULE_EMISSION_IN_WMO = BuiltinMacros.declareBooleanMacro("SWIFT_EAGER_MODULE_EMISSION_IN_WMO")
    public static let SWIFT_ENABLE_EXPLICIT_MODULES = BuiltinMacros.declareEnumMacro("SWIFT_ENABLE_EXPLICIT_MODULES") as EnumMacroDeclaration<SwiftEnableExplicitModulesSetting>
    public static let _SWIFT_EXPLICIT_MODULES_ALLOW_CXX_INTEROP = BuiltinMacros.declareBooleanMacro("_SWIFT_EXPLICIT_MODULES_ALLOW_CXX_INTEROP")
    public static let _SWIFT_EXPLICIT_MODULES_ALLOW_BEFORE_SWIFT_5 = BuiltinMacros.declareBooleanMacro("_SWIFT_EXPLICIT_MODULES_ALLOW_BEFORE_SWIFT_5")
    public static let _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES = BuiltinMacros.declareEnumMacro("_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES") as EnumMacroDeclaration<SwiftEnableExplicitModulesSetting>
    public static let SWIFT_ENABLE_TESTABILITY = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_TESTABILITY")
    public static let SWIFT_EXEC = BuiltinMacros.declarePathMacro("SWIFT_EXEC")
    public static let SWIFT_FORCE_DYNAMIC_LINK_STDLIB = BuiltinMacros.declareBooleanMacro("SWIFT_FORCE_DYNAMIC_LINK_STDLIB")
    public static let SWIFT_FORCE_STATIC_LINK_STDLIB = BuiltinMacros.declareBooleanMacro("SWIFT_FORCE_STATIC_LINK_STDLIB")
    public static let SWIFT_FORCE_SYSTEM_LINK_STDLIB = BuiltinMacros.declareBooleanMacro("SWIFT_FORCE_SYSTEM_LINK_STDLIB")
    public static let SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES = BuiltinMacros.declareStringListMacro("SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES")
    public static let SWIFT_LOAD_BINARY_MACROS = BuiltinMacros.declareStringListMacro("SWIFT_LOAD_BINARY_MACROS")
    public static let SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS = BuiltinMacros.declareBooleanMacro("SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS")
    public static let SWIFT_INCLUDE_PATHS = BuiltinMacros.declarePathListMacro("SWIFT_INCLUDE_PATHS")
    public static let SWIFT_INDEX_STORE_ENABLE = BuiltinMacros.declareBooleanMacro("SWIFT_INDEX_STORE_ENABLE")
    public static let SWIFT_INDEX_STORE_PATH = BuiltinMacros.declarePathMacro("SWIFT_INDEX_STORE_PATH")
    public static let SWIFT_INSTALL_OBJC_HEADER = BuiltinMacros.declareBooleanMacro("SWIFT_INSTALL_OBJC_HEADER")
    public static let SWIFT_INSTALLAPI_LAZY_TYPECHECK = BuiltinMacros.declareBooleanMacro("SWIFT_INSTALLAPI_LAZY_TYPECHECK")
    public static let SWIFT_LIBRARIES_ONLY = BuiltinMacros.declareBooleanMacro("SWIFT_LIBRARIES_ONLY")
    public static let SWIFT_LIBRARY_LEVEL = BuiltinMacros.declareStringMacro("SWIFT_LIBRARY_LEVEL")
    public static let SWIFT_LIBRARY_PATH = BuiltinMacros.declarePathMacro("SWIFT_LIBRARY_PATH")
    public static let SWIFT_LTO = BuiltinMacros.declareEnumMacro("SWIFT_LTO") as EnumMacroDeclaration<LTOSetting>
    public static let SWIFT_MODULE_NAME = BuiltinMacros.declareStringMacro("SWIFT_MODULE_NAME")
    public static let SWIFT_MODULE_ALIASES = BuiltinMacros.declareStringListMacro("SWIFT_MODULE_ALIASES")
    public static let SWIFT_WARNINGS_AS_WARNINGS_GROUPS = BuiltinMacros.declareStringListMacro("SWIFT_WARNINGS_AS_WARNINGS_GROUPS")
    public static let SWIFT_WARNINGS_AS_ERRORS_GROUPS = BuiltinMacros.declareStringListMacro("SWIFT_WARNINGS_AS_ERRORS_GROUPS")
    public static let SWIFT_OBJC_BRIDGING_HEADER = BuiltinMacros.declareStringMacro("SWIFT_OBJC_BRIDGING_HEADER")
    public static let SWIFT_OBJC_INTERFACE_HEADER_NAME = BuiltinMacros.declareStringMacro("SWIFT_OBJC_INTERFACE_HEADER_NAME")
    public static let SWIFT_OBJC_INTERFACE_HEADER_DIR = BuiltinMacros.declareStringMacro("SWIFT_OBJC_INTERFACE_HEADER_DIR")
    public static let SWIFT_OBJC_INTEROP_MODE = BuiltinMacros.declareStringMacro("SWIFT_OBJC_INTEROP_MODE")
    public static let SWIFT_OPTIMIZATION_LEVEL = BuiltinMacros.declareStringMacro("SWIFT_OPTIMIZATION_LEVEL")
    public static let SWIFT_PACKAGE_NAME = BuiltinMacros.declareStringMacro("SWIFT_PACKAGE_NAME")
    public static let SWIFT_SYSTEM_INCLUDE_PATHS = BuiltinMacros.declarePathListMacro("SWIFT_SYSTEM_INCLUDE_PATHS")
    public static let PACKAGE_RESOURCE_BUNDLE_NAME = BuiltinMacros.declareStringMacro("PACKAGE_RESOURCE_BUNDLE_NAME")
    public static let PACKAGE_RESOURCE_TARGET_KIND = BuiltinMacros.declareEnumMacro("PACKAGE_RESOURCE_TARGET_KIND") as EnumMacroDeclaration<PackageResourceTargetKind>
    public static let USE_SWIFT_RESPONSE_FILE = BuiltinMacros.declareBooleanMacro("USE_SWIFT_RESPONSE_FILE") // remove in rdar://53000820
    public static let SWIFT_INSTALL_MODULE = BuiltinMacros.declareBooleanMacro("SWIFT_INSTALL_MODULE")
    public static let SWIFT_INSTALL_MODULE_FOR_DEPLOYMENT = BuiltinMacros.declareBooleanMacro("SWIFT_INSTALL_MODULE_FOR_DEPLOYMENT")
    public static let SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR = BuiltinMacros.declareBooleanMacro("SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR")
    public static let SWIFT_STDLIB = BuiltinMacros.declareStringMacro("SWIFT_STDLIB")
    public static let SWIFT_STDLIB_TOOL = BuiltinMacros.declareStringMacro("SWIFT_STDLIB_TOOL")
    public static let SWIFT_STDLIB_TOOL_FOLDERS_TO_SCAN = BuiltinMacros.declarePathListMacro("SWIFT_STDLIB_TOOL_FOLDERS_TO_SCAN")
    public static let SWIFT_TARGET_TRIPLE = BuiltinMacros.declareStringMacro("SWIFT_TARGET_TRIPLE")
    public static let SWIFT_TARGET_TRIPLE_VARIANTS = BuiltinMacros.declareStringListMacro("SWIFT_TARGET_TRIPLE_VARIANTS")
    public static let SWIFT_TOOLS_DIR = BuiltinMacros.declareStringMacro("SWIFT_TOOLS_DIR")
    public static let SWIFT_UNEXTENDED_MODULE_MAP_PATH = BuiltinMacros.declareStringMacro("SWIFT_UNEXTENDED_MODULE_MAP_PATH")
    public static let SWIFT_UNEXTENDED_VFS_OVERLAY_PATH = BuiltinMacros.declareStringMacro("SWIFT_UNEXTENDED_VFS_OVERLAY_PATH")
    public static let SWIFT_UNEXTENDED_INTERFACE_HEADER_PATH = BuiltinMacros.declareStringMacro("SWIFT_UNEXTENDED_INTERFACE_HEADER_PATH")
    public static let SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION = BuiltinMacros.declareBooleanMacro("SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION")
    public static let SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME = BuiltinMacros.declareBooleanMacro("SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME")
    public static let SWIFT_USER_MODULE_VERSION = BuiltinMacros.declareStringMacro("SWIFT_USER_MODULE_VERSION")
    public static let SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION = BuiltinMacros.declareBooleanMacro("SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION")
    public static let SWIFT_VERSION = BuiltinMacros.declareStringMacro("SWIFT_VERSION")
    public static let EFFECTIVE_SWIFT_VERSION = BuiltinMacros.declareStringMacro("EFFECTIVE_SWIFT_VERSION")
    public static let SWIFT_WHOLE_MODULE_OPTIMIZATION = BuiltinMacros.declareBooleanMacro("SWIFT_WHOLE_MODULE_OPTIMIZATION")
    public static let SWIFT_ENABLE_COMPILE_CACHE = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_COMPILE_CACHE")
    public static let SWIFT_ENABLE_PREFIX_MAPPING = BuiltinMacros.declareBooleanMacro("SWIFT_ENABLE_PREFIX_MAPPING")
    public static let SWIFT_OTHER_PREFIX_MAPPINGS = BuiltinMacros.declareStringListMacro("SWIFT_OTHER_PREFIX_MAPPINGS")
    public static let SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR = BuiltinMacros.declareStringMacro("SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR")
    public static let SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME = BuiltinMacros.declareStringMacro("SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME")
    public static let SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS")
    public static let TAPI_EXTRACT_API_SEARCH_PATHS = BuiltinMacros.declareStringListMacro("TAPI_EXTRACT_API_SEARCH_PATHS")
    public static let TAPI_EXTRACT_API_OUTPUT_DIR = BuiltinMacros.declarePathMacro("TAPI_EXTRACT_API_OUTPUT_DIR")
    public static let TAPI_EXTRACT_API_SDKDB_OUTPUT_PATH = BuiltinMacros.declarePathMacro("TAPI_EXTRACT_API_SDKDB_OUTPUT_PATH")
    public static let SDKDB_TO_SYMGRAPH_EXEC = BuiltinMacros.declarePathMacro("SDKDB_TO_SYMGRAPH_EXEC")
    public static let CLANG_EXTRACT_API_EXEC = BuiltinMacros.declareStringMacro("CLANG_EXTRACT_API_EXEC")
    public static let DOCC_ARCHIVE_PATH = BuiltinMacros.declareStringMacro("DOCC_ARCHIVE_PATH")
    public static let DOCC_EXTRACT_SPI_DOCUMENTATION = BuiltinMacros.declareBooleanMacro("DOCC_EXTRACT_SPI_DOCUMENTATION")
    public static let DOCC_EXTRACT_EXTENSION_SYMBOLS = BuiltinMacros.declareBooleanMacro("DOCC_EXTRACT_EXTENSION_SYMBOLS")
    public static let DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS = BuiltinMacros.declareBooleanMacro("DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS")
    public static let DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS = BuiltinMacros.declareBooleanMacro("DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS")
    public static let DOCC_ENABLE_CXX_SUPPORT = BuiltinMacros.declareBooleanMacro("DOCC_ENABLE_CXX_SUPPORT")
    public static let DOCC_INPUTS = BuiltinMacros.declareStringMacro("DOCC_INPUTS")
    public static let DOCC_EXEC = BuiltinMacros.declarePathMacro("DOCC_EXEC")
    public static let DOCC_TEMPLATE_PATH = BuiltinMacros.declareStringMacro("DOCC_TEMPLATE_PATH")
    public static let DOCC_CATALOG_IDENTIFIER = BuiltinMacros.declareStringMacro("DOCC_CATALOG_IDENTIFIER")
    public static let DOCC_EMIT_FIXITS = BuiltinMacros.declareBooleanMacro("DOCC_EMIT_FIXITS")
    public static let DOCC_IDE_CONSOLE_OUTPUT = BuiltinMacros.declareBooleanMacro("DOCC_IDE_CONSOLE_OUTPUT")
    public static let DOCC_DIAGNOSTICS_FILE = BuiltinMacros.declarePathMacro("DOCC_DIAGNOSTICS_FILE")
    public static let RUN_DOCUMENTATION_COMPILER = BuiltinMacros.declareBooleanMacro("RUN_DOCUMENTATION_COMPILER")
    public static let SKIP_BUILDING_DOCUMENTATION = BuiltinMacros.declareBooleanMacro("SKIP_BUILDING_DOCUMENTATION")
    public static let RUN_SYMBOL_GRAPH_EXTRACT = BuiltinMacros.declareBooleanMacro("RUN_SYMBOL_GRAPH_EXTRACT")
    public static let SYSTEM_EXTENSIONS_FOLDER_PATH = BuiltinMacros.declarePathMacro("SYSTEM_EXTENSIONS_FOLDER_PATH")
    public static let SYSTEM_FRAMEWORK_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("SYSTEM_FRAMEWORK_SEARCH_PATHS")
    public static let SYSTEM_FRAMEWORK_SEARCH_PATHS_USE_FSYSTEM = BuiltinMacros.declareBooleanMacro("SYSTEM_FRAMEWORK_SEARCH_PATHS_USE_FSYSTEM")
    public static let SYSTEM_HEADER_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("SYSTEM_HEADER_SEARCH_PATHS")
    public static let TapiFileListPath = BuiltinMacros.declareStringMacro("TapiFileListPath")
    public static let TAPI_DYLIB_INSTALL_NAME = BuiltinMacros.declareStringMacro("TAPI_DYLIB_INSTALL_NAME")
    public static let TAPI_ENABLE_MODULES = BuiltinMacros.declareBooleanMacro("TAPI_ENABLE_MODULES")
    public static let TAPI_ENABLE_PROJECT_HEADERS = BuiltinMacros.declareBooleanMacro("TAPI_ENABLE_PROJECT_HEADERS")
    public static let TAPI_USE_SRCROOT = BuiltinMacros.declareBooleanMacro("TAPI_USE_SRCROOT")
    public static let TAPI_ENABLE_VERIFICATION_MODE = BuiltinMacros.declareBooleanMacro("TAPI_ENABLE_VERIFICATION_MODE")
    public static let TAPI_EXEC = BuiltinMacros.declarePathMacro("TAPI_EXEC")
    public static let TAPI_INPUTS = BuiltinMacros.declarePathListMacro("TAPI_INPUTS")
    public static let TAPI_OUTPUT_PATH = BuiltinMacros.declareStringMacro("TAPI_OUTPUT_PATH")
    public static let TAPI_READ_DSYM = BuiltinMacros.declareBooleanMacro("TAPI_READ_DSYM")
    public static let TAPI_RUNPATH_SEARCH_PATHS = BuiltinMacros.declareStringListMacro("TAPI_RUNPATH_SEARCH_PATHS")
    public static let TARGETED_DEVICE_FAMILY = BuiltinMacros.declareStringMacro("TARGETED_DEVICE_FAMILY")
    public static let TEMP_FILES_DIR = BuiltinMacros.declarePathMacro("TEMP_FILES_DIR")
    public static let TEMP_FILE_DIR = BuiltinMacros.declarePathMacro("TEMP_FILE_DIR")
    public static let TEMP_ROOT = BuiltinMacros.declarePathMacro("TEMP_ROOT")
    public static let THIN_PRODUCT_STUB_BINARY = BuiltinMacros.declareBooleanMacro("THIN_PRODUCT_STUB_BINARY")
    public static let TempResourcesDir = BuiltinMacros.declareStringMacro("TempResourcesDir")
    public static let UNEXPORTED_SYMBOLS_FILE = BuiltinMacros.declarePathMacro("UNEXPORTED_SYMBOLS_FILE")
    public static let UNINSTALLED_PRODUCTS_DIR = BuiltinMacros.declarePathMacro("UNINSTALLED_PRODUCTS_DIR")
    public static let UNLOCALIZED_RESOURCES_FOLDER_PATH = BuiltinMacros.declarePathMacro("UNLOCALIZED_RESOURCES_FOLDER_PATH")
    public static let UnlocalizedProductResourcesDir = BuiltinMacros.declarePathMacro("UnlocalizedProductResourcesDir")
    public static let USER_HEADER_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("USER_HEADER_SEARCH_PATHS")
    public static let USES_SWIFTPM_UNSAFE_FLAGS = BuiltinMacros.declareBooleanMacro("USES_SWIFTPM_UNSAFE_FLAGS")
    public static let USES_XCTRUNNER = BuiltinMacros.declareBooleanMacro("USES_XCTRUNNER")
    public static let USE_HEADERMAP = BuiltinMacros.declareBooleanMacro("USE_HEADERMAP")
    public static let TAPI_HEADER_SEARCH_PATHS = BuiltinMacros.declarePathListMacro("TAPI_HEADER_SEARCH_PATHS")
    public static let USE_HEADER_SYMLINKS = BuiltinMacros.declareBooleanMacro("USE_HEADER_SYMLINKS")
    public static let USE_HIERARCHICAL_LAYOUT_FOR_COPIED_ASIDE_PRODUCTS = BuiltinMacros.declareBooleanMacro("USE_HIERARCHICAL_LAYOUT_FOR_COPIED_ASIDE_PRODUCTS")
    public static let VALIDATE_PLIST_FILES_WHILE_COPYING = BuiltinMacros.declareBooleanMacro("VALIDATE_PLIST_FILES_WHILE_COPYING")
    public static let VALIDATE_PRODUCT = BuiltinMacros.declareBooleanMacro("VALIDATE_PRODUCT")
    public static let VALIDATE_DEPENDENCIES = BuiltinMacros.declareEnumMacro("VALIDATE_DEPENDENCIES") as EnumMacroDeclaration<BooleanWarningLevel>
    public static let VALIDATE_DEVELOPMENT_ASSET_PATHS = BuiltinMacros.declareEnumMacro("VALIDATE_DEVELOPMENT_ASSET_PATHS") as EnumMacroDeclaration<BooleanWarningLevel>
    public static let VECTOR_SUFFIX = BuiltinMacros.declareStringMacro("VECTOR_SUFFIX")
    public static let VERBOSE_PBXCP = BuiltinMacros.declareBooleanMacro("VERBOSE_PBXCP")
    public static let VERSIONING_STUB = BuiltinMacros.declareStringMacro("VERSIONING_STUB")
    public static let VERSIONING_SYSTEM = BuiltinMacros.declareStringMacro("VERSIONING_SYSTEM")
    public static let VERSIONPLIST_PATH = BuiltinMacros.declarePathMacro("VERSIONPLIST_PATH")
    public static let VERSIONS_FOLDER_PATH = BuiltinMacros.declarePathMacro("VERSIONS_FOLDER_PATH")
    public static let VERSION_INFO_EXPORT_DECL = BuiltinMacros.declareStringMacro("VERSION_INFO_EXPORT_DECL")
    public static let VERSION_INFO_FILE = BuiltinMacros.declareStringMacro("VERSION_INFO_FILE")
    public static let VERSION_INFO_PREFIX = BuiltinMacros.declareStringMacro("VERSION_INFO_PREFIX")
    public static let VERSION_INFO_STRING = BuiltinMacros.declareStringMacro("VERSION_INFO_STRING")
    public static let VERSION_INFO_SUFFIX = BuiltinMacros.declareStringMacro("VERSION_INFO_SUFFIX")
    public static let ValidateForStore = BuiltinMacros.declareBooleanMacro("ValidateForStore")
    public static let WARNING_CFLAGS = BuiltinMacros.declareStringListMacro("WARNING_CFLAGS")
    public static let WARNING_LDFLAGS = BuiltinMacros.declareStringListMacro("WARNING_LDFLAGS")
    public static let WATCHKIT_2_SUPPORT_FOLDER_PATH = BuiltinMacros.declareStringMacro("WATCHKIT_2_SUPPORT_FOLDER_PATH")
    public static let WATCHKIT_EXTENSION_MAIN_LDFLAGS = BuiltinMacros.declareStringListMacro("WATCHKIT_EXTENSION_MAIN_LDFLAGS")
    public static let WATCHKIT_EXTENSION_MAIN_LEGACY_SHIM_PATH = BuiltinMacros.declareStringMacro("WATCHKIT_EXTENSION_MAIN_LEGACY_SHIM_PATH")
    public static let WRAPPER_EXTENSION = BuiltinMacros.declareStringMacro("WRAPPER_EXTENSION")
    public static let WARN_ON_VALID_ARCHS_USAGE = BuiltinMacros.declareBooleanMacro("WARN_ON_VALID_ARCHS_USAGE")
    public static let WRAPPER_NAME = BuiltinMacros.declarePathMacro("WRAPPER_NAME")
    public static let XCSTRINGS_LANGUAGES_TO_COMPILE = BuiltinMacros.declareStringListMacro("XCSTRINGS_LANGUAGES_TO_COMPILE")
    public static let XPCSERVICES_FOLDER_PATH = BuiltinMacros.declarePathMacro("XPCSERVICES_FOLDER_PATH")
    public static let YACC = BuiltinMacros.declarePathMacro("YACC")
    public static let YACCFLAGS = BuiltinMacros.declareStringListMacro("YACCFLAGS")
    public static let YACC_GENERATED_FILE_STEM = BuiltinMacros.declareStringMacro("YACC_GENERATED_FILE_STEM")
    public static let _BUILDABLE_SERIALIZATION_KEY = BuiltinMacros.declareStringMacro("_BUILDABLE_SERIALIZATION_KEY")
    public static let _WRAPPER_CONTENTS_DIR = BuiltinMacros.declareStringMacro("_WRAPPER_CONTENTS_DIR")
    public static let _WRAPPER_PARENT_PATH = BuiltinMacros.declareStringMacro("_WRAPPER_PARENT_PATH")
    public static let _WRAPPER_RESOURCES_DIR = BuiltinMacros.declareStringMacro("_WRAPPER_RESOURCES_DIR")
    public static let __INPUT_FILE_LIST_PATH__ = BuiltinMacros.declarePathMacro("__INPUT_FILE_LIST_PATH__")
    public static let SWIFT_RESPONSE_FILE_PATH = BuiltinMacros.declarePathMacro("SWIFT_RESPONSE_FILE_PATH")
    public static let __ARCHS__ = BuiltinMacros.declareStringListMacro("__ARCHS__")

    // MARK: Target Device Properties
    public static let TARGET_DEVICE_OS_VERSION = BuiltinMacros.declareStringMacro("TARGET_DEVICE_OS_VERSION")
    public static let TARGET_DEVICE_PLATFORM_NAME = BuiltinMacros.declareStringMacro("TARGET_DEVICE_PLATFORM_NAME")

    public static let RC_ARCHS = BuiltinMacros.declareStringListMacro("RC_ARCHS")
    public static let RC_BASE_PROJECT_NAME = BuiltinMacros.declareStringMacro("RC_BASE_PROJECT_NAME")
    public static let RC_ProjectName = BuiltinMacros.declareStringMacro("RC_ProjectName")

    // LLVM Target
    public static let LLVM_TARGET_TRIPLE_OS_VERSION = BuiltinMacros.declareStringMacro("LLVM_TARGET_TRIPLE_OS_VERSION")
    public static let LLVM_TARGET_TRIPLE_VENDOR = BuiltinMacros.declareStringMacro("LLVM_TARGET_TRIPLE_VENDOR")

    // On-Demand Resources
    public static let ENABLE_ON_DEMAND_RESOURCES = BuiltinMacros.declareBooleanMacro("ENABLE_ON_DEMAND_RESOURCES")
    public static let ASSET_PACK_FOLDER_PATH = BuiltinMacros.declareStringMacro("ASSET_PACK_FOLDER_PATH")
    public static let EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE = BuiltinMacros.declareBooleanMacro("EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE")
    public static let WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES = BuiltinMacros.declareBooleanMacro("WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES")
    public static let ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS = BuiltinMacros.declareStringListMacro("ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS")
    public static let ON_DEMAND_RESOURCES_PREFETCH_ORDER = BuiltinMacros.declareStringListMacro("ON_DEMAND_RESOURCES_PREFETCH_ORDER")
    public static let ASSET_PACK_MANIFEST_URL_PREFIX = BuiltinMacros.declareStringMacro("ASSET_PACK_MANIFEST_URL_PREFIX")
    public static let DEVELOPMENT_ASSET_PATHS = BuiltinMacros.declareStringListMacro("DEVELOPMENT_ASSET_PATHS")

    // App Playground Asset Catalog Generation
    public static let APP_PLAYGROUND_ASSET_CATALOG_GENERATOR = BuiltinMacros.declarePathMacro("APP_PLAYGROUND_ASSET_CATALOG_GENERATOR")
    public static let APP_PLAYGROUND_GENERATE_ASSET_CATALOG = BuiltinMacros.declareBooleanMacro("APP_PLAYGROUND_GENERATE_ASSET_CATALOG")
    public static let APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE = BuiltinMacros.declarePathMacro("APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE")
    public static let APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PLACEHOLDER_APPICON = BuiltinMacros.declareStringMacro("APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PLACEHOLDER_APPICON")
    public static let APP_PLAYGROUND_GENERATED_ASSET_CATALOG_APPICON_NAME = BuiltinMacros.declareStringMacro("APP_PLAYGROUND_GENERATED_ASSET_CATALOG_APPICON_NAME")
    public static let APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PRESET_ACCENT_COLOR = BuiltinMacros.declareStringMacro("APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PRESET_ACCENT_COLOR")
    public static let APP_PLAYGROUND_GENERATED_ASSET_CATALOG_GLOBAL_ACCENT_COLOR_NAME = BuiltinMacros.declareStringMacro("APP_PLAYGROUND_GENERATED_ASSET_CATALOG_GLOBAL_ACCENT_COLOR_NAME")

    // MARK: Info.plist Properties
    // Info.plist Keys -  General
    public static let INFOPLIST_KEY_CFBundleDisplayName = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_CFBundleDisplayName")
    public static let INFOPLIST_KEY_LSApplicationCategoryType = BuiltinMacros.declareEnumMacro("INFOPLIST_KEY_LSApplicationCategoryType") as EnumMacroDeclaration<ApplicationCategory>
    public static let INFOPLIST_KEY_NSHumanReadableCopyright = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSHumanReadableCopyright")
    public static let INFOPLIST_KEY_NSPrincipalClass = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSPrincipalClass")

    // Info.plist Keys - Usage Descriptions
    public static let INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption")
    public static let INFOPLIST_KEY_ITSEncryptionExportComplianceCode = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_ITSEncryptionExportComplianceCode")
    public static let INFOPLIST_KEY_NFCReaderUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NFCReaderUsageDescription")
    public static let INFOPLIST_KEY_NSAppleEventsUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSAppleEventsUsageDescription")
    public static let INFOPLIST_KEY_NSAppleMusicUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSAppleMusicUsageDescription")
    public static let INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription")
    public static let INFOPLIST_KEY_NSBluetoothPeripheralUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSBluetoothPeripheralUsageDescription")
    public static let INFOPLIST_KEY_NSBluetoothWhileInUseUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSBluetoothWhileInUseUsageDescription")
    public static let INFOPLIST_KEY_NSCalendarsUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSCalendarsUsageDescription")
    public static let INFOPLIST_KEY_NSCameraUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSCameraUsageDescription")
    public static let INFOPLIST_KEY_NSContactsUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSContactsUsageDescription")
    public static let INFOPLIST_KEY_NSDesktopFolderUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSDesktopFolderUsageDescription")
    public static let INFOPLIST_KEY_NSDocumentsFolderUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSDocumentsFolderUsageDescription")
    public static let INFOPLIST_KEY_NSDownloadsFolderUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSDownloadsFolderUsageDescription")
    public static let INFOPLIST_KEY_NSFaceIDUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSFaceIDUsageDescription")
    public static let INFOPLIST_KEY_NSFallDetectionUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSFallDetectionUsageDescription")
    public static let INFOPLIST_KEY_NSFileProviderDomainUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSFileProviderDomainUsageDescription")
    public static let INFOPLIST_KEY_NSFileProviderPresenceUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSFileProviderPresenceUsageDescription")
    public static let INFOPLIST_KEY_NSFocusStatusUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSFocusStatusUsageDescription")
    public static let INFOPLIST_KEY_NSGKFriendListUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSGKFriendListUsageDescription")
    public static let INFOPLIST_KEY_NSHealthClinicalHealthRecordsShareUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSHealthClinicalHealthRecordsShareUsageDescription")
    public static let INFOPLIST_KEY_NSHealthShareUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSHealthShareUsageDescription")
    public static let INFOPLIST_KEY_NSHealthUpdateUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSHealthUpdateUsageDescription")
    public static let INFOPLIST_KEY_NSHomeKitUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSHomeKitUsageDescription")
    public static let INFOPLIST_KEY_NSIdentityUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSIdentityUsageDescription")
    public static let INFOPLIST_KEY_NSLocalNetworkUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSLocalNetworkUsageDescription")
    public static let INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription")
    public static let INFOPLIST_KEY_NSLocationAlwaysUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSLocationAlwaysUsageDescription")
    public static let INFOPLIST_KEY_NSLocationTemporaryUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSLocationTemporaryUsageDescription")
    public static let INFOPLIST_KEY_NSLocationUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSLocationUsageDescription")
    public static let INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSLocationWhenInUseUsageDescription")
    public static let INFOPLIST_KEY_NSMicrophoneUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSMicrophoneUsageDescription")
    public static let INFOPLIST_KEY_NSMotionUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSMotionUsageDescription")
    public static let INFOPLIST_KEY_NSNearbyInteractionAllowOnceUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSNearbyInteractionAllowOnceUsageDescription")
    public static let INFOPLIST_KEY_NSNearbyInteractionUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSNearbyInteractionUsageDescription")
    public static let INFOPLIST_KEY_NSNetworkVolumesUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSNetworkVolumesUsageDescription")
    public static let INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription")
    public static let INFOPLIST_KEY_NSPhotoLibraryUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSPhotoLibraryUsageDescription")
    public static let INFOPLIST_KEY_NSRemindersUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSRemindersUsageDescription")
    public static let INFOPLIST_KEY_NSRemovableVolumesUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSRemovableVolumesUsageDescription")
    public static let INFOPLIST_KEY_NSSensorKitPrivacyPolicyURL = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSSensorKitPrivacyPolicyURL")
    public static let INFOPLIST_KEY_NSSensorKitUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSSensorKitUsageDescription")
    public static let INFOPLIST_KEY_NSSiriUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSSiriUsageDescription")
    public static let INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSSpeechRecognitionUsageDescription")
    public static let INFOPLIST_KEY_NSSystemAdministrationUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSSystemAdministrationUsageDescription")
    public static let INFOPLIST_KEY_NSSystemExtensionUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSSystemExtensionUsageDescription")
    public static let INFOPLIST_KEY_NSUserTrackingUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSUserTrackingUsageDescription")
    public static let INFOPLIST_KEY_NSVideoSubscriberAccountUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSVideoSubscriberAccountUsageDescription")
    public static let INFOPLIST_KEY_NSVoIPUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSVoIPUsageDescription")
    public static let INFOPLIST_KEY_OSBundleUsageDescription = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_OSBundleUsageDescription")

    // Info.plist Keys - macOS
    public static let INFOPLIST_KEY_LSBackgroundOnly = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_LSBackgroundOnly")
    public static let INFOPLIST_KEY_LSUIElement = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_LSUIElement")
    public static let INFOPLIST_KEY_NSMainNibFile = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSMainNibFile")
    public static let INFOPLIST_KEY_NSMainStoryboardFile = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_NSMainStoryboardFile")

    // Info.plist Keys - iOS and Derived Platforms
    public static let INFOPLIST_KEY_UILaunchScreen_Generation = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_UILaunchScreen_Generation")
    public static let INFOPLIST_KEY_UILaunchStoryboardName = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_UILaunchStoryboardName")
    public static let INFOPLIST_KEY_UIMainStoryboardFile = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_UIMainStoryboardFile")
    public static let INFOPLIST_KEY_UIRequiredDeviceCapabilities = BuiltinMacros.declareStringListMacro("INFOPLIST_KEY_UIRequiredDeviceCapabilities")
    public static let INFOPLIST_KEY_UISupportedInterfaceOrientations = BuiltinMacros.declareStringListMacro("INFOPLIST_KEY_UISupportedInterfaceOrientations")
    public static let INFOPLIST_KEY_UIUserInterfaceStyle = BuiltinMacros.declareEnumMacro("INFOPLIST_KEY_UIUserInterfaceStyle") as EnumMacroDeclaration<UserInterfaceStyle>

    // Info.plist Keys - iOS
    public static let INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace")
    public static let INFOPLIST_KEY_NSSupportsLiveActivities = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_NSSupportsLiveActivities")
    public static let INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates")
    public static let INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents")
    public static let INFOPLIST_KEY_UIApplicationSceneManifest_Generation = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_UIApplicationSceneManifest_Generation")
    public static let INFOPLIST_KEY_UIRequiresFullScreen = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_UIRequiresFullScreen")
    public static let INFOPLIST_KEY_UIStatusBarHidden = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_UIStatusBarHidden")
    public static let INFOPLIST_KEY_UIStatusBarStyle = BuiltinMacros.declareEnumMacro("INFOPLIST_KEY_UIStatusBarStyle") as EnumMacroDeclaration<StatusBarStyle>
    public static let INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = BuiltinMacros.declareStringListMacro("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad")
    public static let INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = BuiltinMacros.declareStringListMacro("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone")
    public static let INFOPLIST_KEY_UISupportsDocumentBrowser = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_UISupportsDocumentBrowser")

    // Info.plist Keys - watchOS
    public static let INFOPLIST_KEY_CLKComplicationPrincipalClass = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_CLKComplicationPrincipalClass")
    public static let __SKIP_INJECT_INFOPLIST_KEY_WKApplication = BuiltinMacros.declareBooleanMacro("__SKIP_INJECT_INFOPLIST_KEY_WKApplication")
    public static let INFOPLIST_KEY_WKApplication = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_WKApplication")
    public static let INFOPLIST_KEY_WKCompanionAppBundleIdentifier = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_WKCompanionAppBundleIdentifier")
    public static let INFOPLIST_KEY_WKExtensionDelegateClassName = BuiltinMacros.declareStringMacro("INFOPLIST_KEY_WKExtensionDelegateClassName")
    public static let INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp")
    public static let INFOPLIST_KEY_WKWatchOnly = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_WKWatchOnly")
    public static let INFOPLIST_KEY_WKSupportsLiveActivityLaunchAttributeTypes = BuiltinMacros.declareStringListMacro("INFOPLIST_KEY_WKSupportsLiveActivityLaunchAttributeTypes")
    // Info.plist Keys - Metal
    public static let INFOPLIST_KEY_MetalCaptureEnabled = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_MetalCaptureEnabled")

    // Info.plist Keys - Game Controller and Game Mode
    public static let INFOPLIST_KEY_GCSupportsControllerUserInteraction = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_GCSupportsControllerUserInteraction")
    public static let INFOPLIST_KEY_GCSupportsGameMode = BuiltinMacros.declareBooleanMacro("INFOPLIST_KEY_GCSupportsGameMode")

    // Info.plist Keys - Sticker Packs
    public static let INFOPLIST_KEY_NSStickerSharingLevel = BuiltinMacros.declareEnumMacro("INFOPLIST_KEY_NSStickerSharingLevel") as EnumMacroDeclaration<StickerSharingLevel>

    // MARK: Built-in Macro Initialization

    private static var initialized = false

    /// The actual built-in namespace, which is not exposed directly.
    private static let builtinNamespace = MacroNamespace(debugDescription: "builtin")

    static func declareConditionParameter(_ name: String) -> MacroConditionParameter {
        precondition(!initialized)
        return builtinNamespace.declareConditionParameter(name)
    }

    @_spi(MacroDeclarationRegistration) public static func declareBooleanMacro(_ name: String) -> BooleanMacroDeclaration {
        precondition(!initialized)
        return try! builtinNamespace.declareBooleanMacro(name)
    }

    /// Declare an enum macro.
    ///
    /// - Note: **All enum macros should also be handled in the switch case in `declareMacro` in `EnumBuildOptionType`**
    @_spi(MacroDeclarationRegistration) public static func declareEnumMacro<T: EnumerationMacroType>(_ name: String) -> EnumMacroDeclaration<T> {
        precondition(!initialized)
        return try! builtinNamespace.declareEnumMacro(name)
    }

    @_spi(MacroDeclarationRegistration) public static func declareStringMacro(_ name: String) -> StringMacroDeclaration {
        precondition(!initialized)
        return try! builtinNamespace.declareStringMacro(name)
    }
    @_spi(MacroDeclarationRegistration) public static func declareStringListMacro(_ name: String) -> StringListMacroDeclaration {
        precondition(!initialized)
        return try! builtinNamespace.declareStringListMacro(name)
    }

    @_spi(MacroDeclarationRegistration) public static func declarePathMacro(_ name: String) -> PathMacroDeclaration {
        precondition(!initialized)
        return try! builtinNamespace.declarePathMacro(name)
    }
    @_spi(MacroDeclarationRegistration) public static func declarePathListMacro(_ name: String) -> PathListMacroDeclaration {
        precondition(!initialized)
        return try! builtinNamespace.declarePathListMacro(name)
    }


    private static let namespaceInitializationMutex = SWBMutex(())

    /// Public access to the namespace forces initialization.
    public static var namespace: MacroNamespace {
        // Force initialization, if necessary.
        namespaceInitializationMutex.withLock {
            if !BuiltinMacros.initialized {
                BuiltinMacros.initialize()
            }
        }

        return builtinNamespace
    }

    /// Force initialization of all builtin macros.
    private static let allBuiltinMacros = [
        __108704016_DEVELOPER_TOOLCHAIN_DIR_MISUSE_IS_WARNING,
        ACTION,
        ADDITIONAL_SDKS,
        ADDITIONAL_SDK_DIRS,
        AD_HOC_CODE_SIGNING_ALLOWED,
        __AD_HOC_CODE_SIGNING_NOT_ALLOWED_SUPPLEMENTAL_MESSAGE,
        AGGREGATE_TRACKED_DOMAINS,
        ALLOW_BUILD_REQUEST_OVERRIDES,
        ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES,
        DIAGNOSE_SKIP_DEPENDENCIES_USAGE,
        ALLOW_TARGET_PLATFORM_SPECIALIZATION,
        ALLOW_UNSUPPORTED_TEXT_BASED_API,
        ALL_OTHER_LDFLAGS,
        ALL_SETTINGS,
        ALTERNATE_GROUP,
        LINKER_DRIVER,
        ALTERNATE_LINKER,
        ALTERNATE_MODE,
        ALTERNATE_OWNER,
        ALTERNATE_PERMISSIONS_FILES,
        ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES,
        ALWAYS_SEARCH_USER_PATHS,
        ALWAYS_USE_SEPARATE_HEADERMAPS,
        APP_INTENTS_METADATA_PATH,
        APP_INTENTS_DEPLOYMENT_POSTPROCESSING,
        APP_PLAYGROUND_ASSET_CATALOG_GENERATOR,
        APP_PLAYGROUND_GENERATE_ASSET_CATALOG,
        APP_PLAYGROUND_GENERATED_ASSET_CATALOG_APPICON_NAME,
        APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE,
        APP_PLAYGROUND_GENERATED_ASSET_CATALOG_GLOBAL_ACCENT_COLOR_NAME,
        APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PLACEHOLDER_APPICON,
        APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PRESET_ACCENT_COLOR,
        APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING,
        APPLICATION_EXTENSION_API_ONLY,
        __APPLICATION_EXTENSION_API_DOWNGRADE_APPEX_ERROR,
        APPLY_RULES_IN_COPY_FILES,
        APPLY_RULES_IN_COPY_HEADERS,
        APPLY_RULES_IN_INSTALLAPI,
        ARCHS,
        ARCHS_STANDARD,
        ARCHS_STANDARD_32_64_BIT_PRE_XCODE_3_1,
        ARCHS_STANDARD_32_BIT_PRE_XCODE_3_1,
        ARCHS_STANDARD_64_BIT,
        ARCHS_STANDARD_INCLUDING_64_BIT,
        ASSETCATALOG_COMPILER_DEPENDENCY_INFO_FILE,
        ASSETCATALOG_COMPILER_INCLUDE_STICKER_CONTENT,
        ASSETCATALOG_COMPILER_INFOPLIST_CONTENT_FILE,
        ASSETCATALOG_COMPILER_INPUTS,
        ASSETCATALOG_COMPILER_STICKER_PACK_STRINGS,
        ASSETCATALOG_COMPILER_BUNDLE_IDENTIFIER,
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS,
        ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS,
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS,
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_WARNINGS,
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_ERRORS,
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_BACKWARDS_DEPLOYMENT_SUPPORT,
        ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOLS_PATH,
        ASSETCATALOG_COMPILER_GENERATE_OBJC_ASSET_SYMBOLS_PATH,
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH,
        ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT,
        ASSETCATALOG_EXEC,
        AUTOMATICALLY_MERGE_DEPENDENCIES,
        AVAILABLE_PLATFORMS,
        AdditionalCommandLineArguments,
        AppIdentifierPrefix,
        BLOCKLISTS_PATH,
        BUILD_COMPONENTS,
        BUILD_DESCRIPTION_CACHE_DIR,
        BUILD_DIR,
        BUILD_LIBRARY_FOR_DISTRIBUTION,
        BUILD_PACKAGE_FOR_DISTRIBUTION,
        BUILD_STYLE,
        BUILD_VARIANTS,
        BUILT_PRODUCTS_DIR,
        BuiltBinaryPath,
        BUNDLE_FORMAT,
        BUNDLE_LOADER,
        CACHE_ROOT,
        C_COMPILER_LAUNCHER,
        CC,
        CCHROOT,
        CFBundleIdentifier,
        CHMOD,
        CHOWN,
        CLANG_CACHE_ENABLE_LAUNCHER,
        CLANG_CACHE_FALLBACK_IF_UNAVAILABLE,
        CLANG_CXX_LIBRARY,
        CLANG_DIAGNOSTICS_FILE,
        CLANG_ENABLE_COMPILE_CACHE,
        CLANG_CACHE_FINE_GRAINED_OUTPUTS,
        CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION,
        CLANG_DISABLE_DEPENDENCY_INFO_FILE,
        CLANG_ENABLE_PREFIX_MAPPING,
        CLANG_OTHER_PREFIX_MAPPINGS,
        CLANG_DISABLE_SERIALIZED_DIAGNOSTICS,
        CLANG_ENABLE_MODULES,
        CLANG_DISABLE_CXX_MODULES,
        CLANG_ENABLE_MODULE_DEBUGGING,
        CLANG_ENABLE_OBJC_ARC,
        CLANG_ENABLE_EXPLICIT_MODULES,
        _EXPERIMENTAL_CLANG_EXPLICIT_MODULES,
        CLANG_ENABLE_EXPLICIT_MODULES_OBJECT_FILE_VERIFIER,
        CLANG_ENABLE_EXPLICIT_MODULES_WITH_COMPILER_LAUNCHER,
        CLANG_EXPLICIT_MODULES_LIBCLANG_PATH,
        CLANG_EXPLICIT_MODULES_IGNORE_LIBCLANG_VERSION_MISMATCH,
        CLANG_EXPLICIT_MODULES_OUTPUT_PATH,
        SWIFT_EXPLICIT_MODULES_OUTPUT_PATH,
        CLANG_EXTRACT_API_EXEC,
        CLANG_GENERATE_OPTIMIZATION_REMARKS,
        CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER,
        CLANG_IMPORT_PREFIX_HEADER_AS_MODULE,
        CLANG_INDEX_STORE_ENABLE,
        CLANG_INDEX_STORE_PATH,
        CLANG_INSTRUMENT_FOR_OPTIMIZATION_PROFILING,
        CLANG_MODULES_BUILD_SESSION_FILE,
        CLANG_MODULE_LSV,
        CLANG_OBJC_MODERNIZE_DIR,
        CLANG_OPTIMIZATION_PROFILE_FILE,
        CLANG_STATIC_ANALYZER_MODE,
        CLANG_STAT_CACHE_EXEC,
        CLANG_TARGET_TRIPLE_VARIANTS,
        CLANG_USE_OPTIMIZATION_PROFILE,
        CLANG_USE_RESPONSE_FILE,
        CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING,
        CLANG_WARN_COMMA,
        CLANG_WARN_FLOAT_CONVERSION,
        CLANG_WARN_IMPLICIT_FALLTHROUGH,
        CLANG_WARN_NON_LITERAL_NULL_CONVERSION,
        CLANG_WARN_OBJC_LITERAL_CONVERSION,
        CLANG_WARN_STRICT_PROTOTYPES,
        CLONE_HEADERS,
        CODESIGNING_FOLDER_PATH,
        CODESIGN,
        CODESIGN_ALLOCATE,
        CODE_SIGNING_ALLOWED,
        CODE_SIGNING_REQUIRED,
        CODE_SIGNING_REQUIRES_TEAM,
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION,
        CODE_SIGN_ENTITLEMENTS,
        CODE_SIGN_ENTITLEMENTS_CONTENTS,
        CODE_SIGN_IDENTIFIER,
        CODE_SIGN_IDENTITY,
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS,
        CODE_SIGN_LOCAL_EXECUTION_IDENTITY,
        CODE_SIGN_KEYCHAIN,
        CODE_SIGN_RESOURCE_RULES_PATH,
        CODE_SIGN_RESTRICT,
        CODE_SIGN_STYLE,
        COMBINE_HIDPI_IMAGES,
        COMPILER_WORKING_DIRECTORY,
        MERGEABLE_LIBRARY,
        COMPILATION_CACHE_ENABLE_DETACHED_KEY_QUERIES,
        COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS,
        COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES,
        COMPILATION_CACHE_ENABLE_PLUGIN,
        COMPILATION_CACHE_ENABLE_STRICT_CAS_ERRORS,
        COMPILATION_CACHE_KEEP_CAS_DIRECTORY,
        COMPILATION_CACHE_LIMIT_PERCENT,
        COMPILATION_CACHE_LIMIT_SIZE,
        COMPILATION_CACHE_CAS_PATH,
        COMPILATION_CACHE_PLUGIN_PATH,
        COMPILATION_CACHE_REMOTE_SERVICE_PATH,
        COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES,
        COMPRESS_PNG_FILES,
        CONFIGURATION,
        CONFIGURATION_BUILD_DIR,
        CONFIGURATION_TEMP_DIR,
        CONTENTS_FOLDER_PATH,
        COPYING_PRESERVES_HFS_DATA,
        COPY_HEADERS_RUN_UNIFDEF,
        COPY_HEADERS_UNIFDEF_FLAGS,
        COPY_PHASE_STRIP,
        COREML_CODEGEN_LANGUAGE,
        COREML_CODEGEN_SWIFT_VERSION,
        COREML_CODEGEN_SWIFT_GLOBAL_MODULE,
        CORRESPONDING_DEVICE_PLATFORM_DIR,
        CORRESPONDING_DEVICE_PLATFORM_NAME,
        CORRESPONDING_SIMULATOR_PLATFORM_DIR,
        CORRESPONDING_SIMULATOR_PLATFORM_NAME,
        CORRESPONDING_DEVICE_SDK_DIR,
        CORRESPONDING_DEVICE_SDK_NAME,
        CORRESPONDING_SIMULATOR_SDK_DIR,
        CORRESPONDING_SIMULATOR_SDK_NAME,
        CP,
        CPLUSPLUS,
        CPP_HEADERMAP_FILE,
        CPP_HEADERMAP_FILE_FOR_ALL_NON_FRAMEWORK_TARGET_HEADERS,
        CPP_HEADERMAP_FILE_FOR_ALL_TARGET_HEADERS,
        CPP_HEADERMAP_FILE_FOR_GENERATED_FILES,
        CPP_HEADERMAP_FILE_FOR_OWN_TARGET_HEADERS,
        CPP_HEADERMAP_FILE_FOR_PROJECT_FILES,
        CPP_HEADERMAP_PRODUCT_HEADERS_VFS_FILE,
        CPP_HEADER_SYMLINKS_DIR,
        CPP_OTHER_PREPROCESSOR_FLAGS,
        CPP_PREFIX_HEADER,
        CPP_PREPROCESSOR_DEFINITIONS,
        CREATE_INFOPLIST_SECTION_IN_BINARY,
        CREATE_UNIVERSAL_STATIC_LIBRARY_USING_LIBTOOL,
        MERGED_BINARY_TYPE,
        CURRENT_ARCH,
        CURRENT_PROJECT_VERSION,
        CURRENT_VARIANT,
        CURRENT_VERSION,
        CodeSignEntitlements,
        DEAD_CODE_STRIPPING,
        DEBUG_INFORMATION_FORMAT,
        DEFAULT_COMPILER,
        DEFAULT_KEXT_INSTALL_PATH,
        DEFINES_MODULE,
        DEPENDENCY_SCOPE_INCLUDES_DIRECT_DEPENDENCIES,
        DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER,
        __DIAGNOSE_DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER_ERROR,
        DEPLOYMENT_LOCATION,
        DEPLOYMENT_POSTPROCESSING,
        DEPLOYMENT_TARGET_SETTING_NAME,
        DEPLOYMENT_TARGET_SUGGESTED_VALUES,
        DERIVED_DATA_DIR,
        DERIVED_FILES_DIR,
        DERIVED_FILE_DIR,
        DERIVED_SOURCES_DIR,
        DEVELOPER_APPLICATIONS_DIR,
        DEVELOPER_BIN_DIR,
        DEVELOPER_DIR,
        DEVELOPER_FRAMEWORKS_DIR,
        DEVELOPER_FRAMEWORKS_DIR_QUOTED,
        DEVELOPER_INSTALL_DIR,
        DEVELOPER_LIBRARY_DIR,
        DEVELOPER_SDK_DIR,
        DEVELOPER_TOOLS_DIR,
        DEVELOPER_USR_DIR,
        DEVELOPMENT_ASSET_PATHS,
        DEVELOPMENT_LANGUAGE,
        DEVELOPMENT_TEAM,
        DEVICE_DEVELOPER_DIR,
        DIAGNOSE_LOCALIZATION_FILE_EXCLUSION,
        DIAGNOSE_MISSING_TARGET_DEPENDENCIES,
        __DIAGNOSE_DEPRECATED_ARCHS,
        DIFF,
        DISABLE_FREEFORM_CODE_SIGN_OPTION_FLAGS,
        _DISCOVER_COMMAND_LINE_LINKER_INPUTS,
        _DISCOVER_COMMAND_LINE_LINKER_INPUTS_INCLUDE_WL,
        DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC,
        DISABLE_INFOPLIST_PLATFORM_PROCESSING,
        DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING,
        DISABLE_STALE_FILE_REMOVAL,
        DISABLE_TEST_HOST_PLATFORM_PROCESSING,
        DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION,
        DOCC_ARCHIVE_PATH,
        DOCC_EXTRACT_SPI_DOCUMENTATION,
        DOCC_EXTRACT_EXTENSION_SYMBOLS,
        DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS,
        DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS,
        DOCC_ENABLE_CXX_SUPPORT,
        DOCC_CATALOG_IDENTIFIER,
        DOCC_INPUTS,
        DOCC_EXEC,
        DOCC_TEMPLATE_PATH,
        DOCC_EMIT_FIXITS,
        DOCC_IDE_CONSOLE_OUTPUT,
        DOCC_DIAGNOSTICS_FILE,
        DONT_CREATE_BUILT_PRODUCTS_DIR_SYMLINKS,
        DONT_EMBED_REEXPORTED_MERGEABLE_LIBRARIES,
        DONT_GENERATE_INFOPLIST_FILE,
        DONT_RUN_SWIFT_STDLIB_TOOL,
        DOWNGRADE_CODESIGN_MISSING_INFO_PLIST_ERROR,
        DRIVERKIT_DEPLOYMENT_TARGET,
        DSTROOT,
        DSYMUTIL_VARIANT_SUFFIX,
        DSYMUTIL_DSYM_SEARCH_PATHS,
        DSYMUTIL_QUIET_OPERATION,
        DT_TOOLCHAIN_DIR,
        DWARF_DSYM_FILE_NAME,
        DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT,
        DWARF_DSYM_FOLDER_PATH,
        DYLIB_COMPATIBILITY_VERSION,
        DYLIB_CURRENT_VERSION,
        DYLIB_INSTALL_NAME_BASE,
        DYNAMIC_LIBRARY_EXTENSION,
        DerivedFilesDir,
        EAGER_COMPILATION_ALLOW_SCRIPTS,
        EAGER_COMPILATION_DISABLE,
        EAGER_LINKING,
        EAGER_LINKING_INTERMEDIATE_TBD_DIR,
        EAGER_LINKING_INTERMEDIATE_TBD_PATH,
        EAGER_PARALLEL_COMPILATION_DISABLE,
        EAGER_COMPILATION_REQUIRE,
        EAGER_LINKING_REQUIRE,
        EFFECTIVE_PLATFORM_NAME,
        EFFECTIVE_PLATFORM_NAME_MAC_CATALYST_USE_DISTINCT_BUILD_DIR,
        EFFECTIVE_PLATFORM_SUFFIX,
        EFFECTIVE_TOOLCHAINS_DIRS,
        EMBEDDED_CONTENT_CONTAINS_SWIFT,
        EMBEDDED_PROFILE_NAME,
        EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES,
        EMIT_FRONTEND_COMMAND_LINES,
        ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING,
        ENABLE_ADDRESS_SANITIZER,
        ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING,
        ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS,
        ENABLE_APPLE_KEXT_CODE_GENERATION,
        ENABLE_DEFAULT_SEARCH_PATHS,
        ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS,
        ENABLE_DEFAULT_SEARCH_PATHS_IN_FRAMEWORK_SEARCH_PATHS,
        ENABLE_DEFAULT_SEARCH_PATHS_IN_LIBRARY_SEARCH_PATHS,
        ENABLE_DEFAULT_SEARCH_PATHS_IN_REZ_SEARCH_PATHS,
        ENABLE_DEFAULT_SEARCH_PATHS_IN_SWIFT_INCLUDE_PATHS,
        ENABLE_CLOUD_SIGNING,
        ENABLE_GENERIC_TASK_CACHING,
        GENERIC_TASK_CACHE_ENABLE_DIAGNOSTIC_REMARKS,
        ENABLE_HARDENED_RUNTIME,
        ENABLE_HEADER_DEPENDENCIES,
        ENABLE_LIBRARY_VALIDATION,
        ENABLE_SYSTEM_SANITIZERS,
        ENABLE_MODULE_VERIFIER,
        ENABLE_POINTER_AUTHENTICATION,
        ENABLE_PROJECT_OVERRIDE_SPECS,
        ENABLE_PREVIEWS,
        ENABLE_DEBUG_DYLIB,
        ENABLE_DEBUG_DYLIB_OVERRIDE,
        ENFORCE_VALID_ARCHS,
        ENABLE_PREVIEWS_DYLIB_OVERRIDE,
        ENABLE_SDK_IMPORTS,
        ENABLE_SIGNATURE_AGGREGATION,
        ENABLE_TESTABILITY,
        ENABLE_TESTING_SEARCH_PATHS,
        ENABLE_PRIVATE_TESTING_SEARCH_PATHS,
        ENABLE_THREAD_SANITIZER,
        ENABLE_UNDEFINED_BEHAVIOR_SANITIZER,
        DISABLE_TASK_SANDBOXING,
        ENABLE_USER_SCRIPT_SANDBOXING,
        ENTITLEMENTS_ALLOWED,
        ENTITLEMENTS_DONT_REMOVE_GET_TASK_ALLOW,
        ENTITLEMENTS_DESTINATION,
        ENTITLEMENTS_REQUIRED,
        EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES,
        EXCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES,
        EXCLUDED_SOURCE_FILE_NAMES,
        __ALLOW_EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES,
        EXCLUDED_USER_SCRIPT_SANDBOXING_PHASE_NAMES,
        EXECUTABLE_FOLDER_PATH,
        EXECUTABLE_NAME,
        EXECUTABLE_PATH,
        __EXPORT_SDK_VARIANT_IN_SCRIPTS,
        EXECUTABLE_DEBUG_DYLIB_PATH,
        EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME,
        EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME,
        EXECUTABLE_DEBUG_DYLIB_MAPPED_PLATFORM,
        EXECUTABLE_BLANK_INJECTION_DYLIB_PATH,
        EXECUTABLE_SUFFIX,
        EXECUTABLE_VARIANT_SUFFIX,
        EXCLUDED_ARCHS,
        EXPANDED_CODE_SIGN_IDENTITY,
        EXPANDED_CODE_SIGN_IDENTITY_NAME,
        EXPANDED_PROVISIONING_PROFILE,
        EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING,
        EXPORTED_SYMBOLS_FILE,
        EXTENSIONS_FOLDER_PATH,
        FRAMEWORKS_FOLDER_PATH,
        FRAMEWORK_SEARCH_PATHS,
        FRAMEWORK_VERSION,
        FULL_PRODUCT_NAME,
        FUSE_BUILD_PHASES,
        FUSE_BUILD_SCRIPT_PHASES,
        RESCHEDULE_INDEPENDENT_HEADERS_PHASES,
        GCC_C_LANGUAGE_STANDARD,
        CLANG_CXX_LANGUAGE_STANDARD,
        GCC_DYNAMIC_NO_PIC,
        GCC_ENABLE_BUILTIN_FUNCTIONS,
        GCC_ENABLE_CPP_EXCEPTIONS,
        GCC_ENABLE_CPP_RTTI,
        GCC_ENABLE_KERNEL_DEVELOPMENT,
        GCC_ENABLE_PASCAL_STRINGS,
        GCC_GENERATE_DEBUGGING_SYMBOLS,
        GCC_GENERATE_PROFILING_CODE,
        GCC_INCREASE_PRECOMPILED_HEADER_SHARING,
        GCC_INLINES_ARE_PRIVATE_EXTERN,
        GCC_INPUT_FILETYPE,
        GCC_LINK_WITH_DYNAMIC_LIBRARIES,
        GCC_NO_COMMON_BLOCKS,
        GCC_OPTIMIZATION_LEVEL,
        GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS,
        GCC_PFE_FILE_C_DIALECTS,
        GCC_PRECOMPILE_PREFIX_HEADER,
        GCC_PREFIX_HEADER,
        GCC_PREPROCESSOR_DEFINITIONS,
        GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS,
        GCC_PRODUCT_TYPE_PREPROCESSOR_DEFINITIONS,
        GCC_SYMBOLS_PRIVATE_EXTERN,
        GCC_THUMB_SUPPORT,
        GCC_USE_STANDARD_INCLUDE_SEARCHING,
        GCC_VERSION,
        GENERATE_EMBED_IN_CODE_ACCESSORS,
        GENERATE_INFOPLIST_FILE,
        GENERATE_KERNEL_MODULE_INFO_FILE,
        GENERATE_MASTER_OBJECT_FILE,
        GENERATE_PKGINFO_FILE,
        GENERATE_RESOURCE_ACCESSORS,
        GENERATE_TEST_ENTRY_POINT,
        GENERATED_TEST_ENTRY_POINT_PATH,
        GENERATE_TEXT_BASED_STUBS,
        GENERATE_INTERMEDIATE_TEXT_BASED_STUBS,
        GID,
        GLOBAL_API_NOTES_PATH,
        GLOBAL_CFLAGS,
        GROUP,
        HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT,
        HEADERMAP_USES_VFS,
        HEADER_SEARCH_PATHS,
        HEADER_OUTPUT_DIR,
        HOME,
        HOST_PLATFORM,
        IBC_REGIONS_AND_STRINGS_FILES,
        IBC_EXEC,
        IGNORE_BUILD_PHASES,
        IGNORE_CREATED_BY_BUILD_SYSTEM_ATTRIBUTE_DURING_CLEAN,
        IIG_EXEC,
        IIG_HEADERS_DIR,
        IMPLICIT_DEPENDENCY_DOMAIN,
        INCLUDED_EXPLICIT_TARGET_DEPENDENCIES,
        INCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES,
        INCLUDED_SOURCE_FILE_NAMES,
        INDEX_BUILD_VARIANT,
        INDEX_DATA_STORE_DIR,
        INDEX_DIRECTORY_REMAP_VFS_FILE,
        INDEX_DISABLE_SCRIPT_EXECUTION,
        INDEX_DISABLE_VFS_DIRECTORY_REMAP,
        INDEX_ENABLE_BUILD_ARENA,
        INDEX_FORCE_SCRIPT_EXECUTION,
        INDEX_PREPARED_MODULE_CONTENT_MARKER_PATH,
        INDEX_PREPARED_TARGET_MARKER_PATH,
        INDEX_REGULAR_BUILD_PRODUCTS_DIR,
        INDEX_REGULAR_BUILD_INTERMEDIATES_DIR,
        INDEX_ENABLE_DATA_STORE,
        INDEX_PRECOMPS_DIR,
        INFOPLIST_ENFORCE_MINIMUM_OS,
        INFOPLIST_EXPAND_BUILD_SETTINGS,
        INFOPLIST_FILE,
        INFOPLIST_FILE_CONTENTS,
        INFOPLIST_OTHER_PREPROCESSOR_FLAGS,
        INFOPLIST_OUTPUT_FORMAT,
        INFOPLIST_PATH,
        INFOPLIST_PREFIX_HEADER,
        INFOPLIST_PREPROCESS,
        INFOPLIST_PREPROCESSOR_DEFINITIONS,
        INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE,
        INLINE_PRIVATE_FRAMEWORKS,
        INPUT_FILE_BASE,
        INPUT_FILE_DIR,
        INPUT_FILE_NAME,
        INPUT_FILE_PATH,
        INPUT_FILE_REGION_PATH_COMPONENT,
        INPUT_FILE_SUFFIX,
        IMPLICIT_DEPENDENCIES_IGNORE_LDFLAGS,
        INSTALLAPI_COPY_PHASE,
        INSTALLAPI_IGNORE_SKIP_INSTALL,
        INSTALLAPI_MODE_ENABLED,
        INSTALLED_PRODUCT_ASIDES,
        INSTALLHDRS_COPY_PHASE,
        INSTALLHDRS_SCRIPT_PHASE,
        INSTALLLOC_LANGUAGE,
        INSTALLLOC_SCRIPT_PHASE,
        INSTALL_DIR,
        INSTALL_GROUP,
        INSTALL_MODE_FLAG,
        INSTALL_OWNER,
        INSTALL_PATH,
        INSTALL_ROOT,
        INSTRUMENTS_PACKAGE_BUILDER_DEPENDENCY_INFO_FILE,
        INTENTS_CODEGEN_LANGUAGE,
        INTERNAL_AUTOMATION_SUPPORT_FRAMEWORK_PATH,
        INTERNAL_TEST_LIBRARIES_OVERRIDE_PATH,
        INTERNAL_TESTING_FRAMEWORK_PATH,
        IOS_UNZIPPERED_TWIN_PREFIX_PATH,
        IPHONEOS_DEPLOYMENT_TARGET,
        IS_MACCATALYST,
        IS_UNOPTIMIZED_BUILD,
        IS_ZIPPERED,
        InfoPlistPath,
        InputFile,
        InputFileAbsolutePath,
        InputFileBase,
        InputFileDir,
        InputFileName,
        InputFilePath,
        InputFileRegionPathComponent,
        InputFileRelativePath,
        InputFileSuffix,
        InputFileTextEncoding,
        InputPath,
        JAVA_ARCHIVE_CLASSES,
        JAVA_FOLDER_PATH,
        KASAN_DEFAULT_CFLAGS,
        KEEP_PRIVATE_EXTERNS,
        KERNEL_EXTENSION_HEADER_SEARCH_PATHS,
        KERNEL_FRAMEWORK_HEADERS,
        __KNOWN_SPI_INSTALL_PATHS,
        LAUNCH_CONSTRAINT_PARENT,
        LAUNCH_CONSTRAINT_RESPONSIBLE,
        LAUNCH_CONSTRAINT_SELF,
        LD,
        LDPLUSPLUS,
        LD_CLIENT_NAME,
        LD_DEPENDENCY_INFO_FILE,
        LD_DYLIB_INSTALL_NAME,
        LD_ENTRY_POINT,
        LD_ENTITLEMENTS_SECTION,
        LD_ENTITLEMENTS_SECTION_DER,
        LD_EXPORT_GLOBAL_SYMBOLS,
        LD_LTO_OBJECT_FILE,
        LD_NO_PIE,
        LD_RUNPATH_SEARCH_PATHS,
        LD_SDK_IMPORTS_FILE,
        LD_WARN_UNUSED_DYLIBS,
        _LD_MULTIARCH,
        _LD_MULTIARCH_PREFIX_MAP,
        LEGACY_DEVELOPER_DIR,
        LEX,
        LEXFLAGS,
        LIBRARIAN,
        LIBRARY_FLAG_NOSPACE,
        LIBRARY_LOAD_CONSTRAINT,
        LIBRARY_SEARCH_PATHS,
        LIBTOOL,
        LIBTOOL_DEPENDENCY_INFO_FILE,
        LIBTOOL_USE_RESPONSE_FILE,
        LINKER,
        LINK_OBJC_RUNTIME,
        LINK_WITH_STANDARD_LIBRARIES,
        LIPO,
        LLVM_LTO,
        LLVM_TARGET_TRIPLE_SUFFIX,
        LM_AUX_CONST_METADATA_LIST_PATH,
        LM_AUX_INTENTS_METADATA_FILES_LIST_PATH,
        LM_AUX_INTENTS_STATIC_METADATA_FILES_LIST_PATH,
        LM_BINARY_PATH,
        LM_FORCE_LINK_GENERATION,
        LM_COMPILE_TIME_EXTRACTION,
        LM_DEPENDENCY_FILES,
        LM_INTENTS_METADATA_FILES_LIST_PATH,
        LM_INTENTS_STATIC_METADATA_FILES_LIST_PATH,
        LM_FORCE_METADATA_OUTPUT,
        LM_OUTPUT_DIR,
        LM_SKIP_METADATA_EXTRACTION,
        LM_SOURCE_FILE_LIST_PATH,
        LM_STRINGSDATA_FILES,
        LM_STRINGS_FILE_PATH_LIST,
        LM_SWIFT_CONST_VALS_LIST_PATH,
        LM_NO_APP_SHORTCUT_LOCALIZATION,
        LOCAL_ADMIN_APPS_DIR,
        LOCAL_APPS_DIR,
        LOCAL_DEVELOPER_DIR,
        LOCAL_DEVELOPER_EXECUTABLES_DIR,
        LOCAL_LIBRARY_DIR,
        LOCALIZATION_EXPORT_SUPPORTED,
        LOCALIZATION_PREFERS_STRING_CATALOGS,
        LOCROOT,
        LOCSYMROOT,
        MACH_O_TYPE,
        MACOSX_DEPLOYMENT_TARGET,
        MACOS_CREATOR,
        MACOS_CREATOR_ARG,
        MACOS_TYPE,
        MACOS_TYPE_ARG,
        MAC_OS_X_PRODUCT_BUILD_VERSION,
        MAC_OS_X_VERSION_ACTUAL,
        MAC_OS_X_VERSION_MAJOR,
        MAC_OS_X_VERSION_MINOR,
        MARKETING_VERSION,
        MERGE_LINKED_LIBRARIES,
        MESSAGES_APPLICATION_EXTENSION_PRODUCT_BINARY_SOURCE_PATH,
        MESSAGES_APPLICATION_EXTENSION_SUPPORT_FOLDER_PATH,
        MESSAGES_APPLICATION_PRODUCT_BINARY_SOURCE_PATH,
        MESSAGES_APPLICATION_SUPPORT_FOLDER_PATH,
        MIG_EXEC,
        MLKIT_CODEGEN_LANGUAGE,
        MLKIT_CODEGEN_SWIFT_VERSION,
        MODULEMAP_FILE,
        MODULEMAP_FILE_CONTENTS,
        MODULEMAP_PATH,
        MODULEMAP_PRIVATE_FILE,
        MODULES_FOLDER_PATH,
        MODULE_CACHE_DIR,
        MODULE_NAME,
        MODULE_START,
        MODULE_STOP,
        MODULE_VERIFIER_KIND,
        MODULE_VERIFIER_LSV,
        MODULE_VERIFIER_SUPPORTED_LANGUAGES,
        MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS,
        MODULE_VERIFIER_TARGET_TRIPLE_ARCHS,
        MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS,
        MODULE_VERSION,
        MTLCOMPILER_DEPENDENCY_INFO_FILE,
        NATIVE_ARCH,
        NATIVE_ARCH_32_BIT,
        NATIVE_ARCH_64_BIT,
        NATIVE_ARCH_ACTUAL,
        OBJCC,
        OBJCPLUSPLUS,
        OBJC_ABI_VERSION,
        OBJECT_FILE_DIR,
        OBJROOT,
        _OBSOLETE_MANUAL_BUILD_ORDER,
        ONLY_ACTIVE_ARCH,
        OPENCLC,
        OPENCL_ARCHS,
        OPENCL_AUTO_VECTORIZE_ENABLE,
        OPENCL_COMPILER_VERSION,
        OPENCL_DENORMS_ARE_ZERO,
        OPENCL_DOUBLE_AS_SINGLE,
        OPENCL_FAST_RELAXED_MATH,
        OPENCL_MAD_ENABLE,
        OPENCL_OPTIMIZATION_LEVEL,
        OPENCL_OTHER_BC_FLAGS,
        OPENCL_PREPROCESSOR_DEFINITIONS,
        OPTIMIZATION_CFLAGS,
        ORDER_FILE,
        OS,
        OTHER_CFLAGS,
        OTHER_CODE_SIGN_FLAGS,
        OTHER_CPLUSPLUSFLAGS,
        OTHER_DOCC_FLAGS,
        OTHER_LDFLAGS,
        OTHER_LIPOFLAGS,
        OTHER_MIGFLAGS,
        OTHER_MODULE_VERIFIER_FLAGS,
        OTHER_PRECOMP_CFLAGS,
        OTHER_RESMERGERFLAGS,
        OTHER_REZFLAGS,
        OTHER_SWIFT_FLAGS,
        OutputFileBase,
        OutputFormat,
        OutputPath,
        OutputFile,
        OutputRelativePath,
        PACKAGE_BUILD_DYNAMICALLY,
        PACKAGE_SKIP_AUTO_EMBEDDING_DYNAMIC_BINARY_FRAMEWORKS,
        PACKAGE_SKIP_AUTO_EMBEDDING_STATIC_BINARY_FRAMEWORKS,
        PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME,
        PACKAGE_TYPE,
        PATH,
        PBXCP_EXCLUDE_SUBPATHS,
        PBXCP_INCLUDE_ONLY_SUBPATHS,
        PBXCP_STRIP_BITCODE,
        PBXCP_STRIP_SUBPATHS,
        PBXCP_STRIP_UNSIGNED_BINARIES,
        PBXCP_BITCODE_STRIP_MODE,
        PBXCP_BITCODE_STRIP_TOOL,
        PER_ARCH_CFLAGS,
        PER_ARCH_LD,
        PER_ARCH_LDPLUSPLUS,
        PER_ARCH_MODULE_FILE_DIR,
        PER_ARCH_OBJECT_FILE_DIR,
        PER_VARIANT_CFLAGS,
        PER_VARIANT_OBJECT_FILE_DIR,
        PER_VARIANT_OTHER_LIPOFLAGS,
        PKGINFO_PATH,
        PLATFORM_DEVELOPER_APPLICATIONS_DIR,
        PLATFORM_DEVELOPER_BIN_DIR,
        PLATFORM_DEVELOPER_LIBRARY_DIR,
        PLATFORM_DEVELOPER_SDK_DIR,
        PLATFORM_DEVELOPER_TOOLS_DIR,
        PLATFORM_DEVELOPER_USR_DIR,
        PLATFORM_DIR,
        PLATFORM_DISPLAY_NAME,
        PLATFORM_FAMILY_NAME,
        PLATFORM_NAME,
        __USE_PLATFORM_NAME_FOR_FILTERS,
        PLATFORM_PREFERRED_ARCH,
        PLATFORM_PRODUCT_BUILD_VERSION,
        PLIST_FILE_OUTPUT_FORMAT,
        PLUGINS_FOLDER_PATH,
        __POPULATE_COMPATIBILITY_ARCH_MAP,
        PRELINK_FLAGS,
        PRELINK_LIBS,
        PRIVATE_HEADERS_FOLDER_PATH,
        PROCESSED_INFOPLIST_PATH,
        PRODUCT_BINARY_SOURCE_PATH,
        PRODUCT_BUNDLE_IDENTIFIER,
        PRODUCT_BUNDLE_PACKAGE_TYPE,
        PRODUCT_DEFINITION_PLIST,
        PRODUCT_MODULE_NAME,
        PRODUCT_NAME,
        PRODUCT_SPECIFIC_LDFLAGS,
        PRODUCT_TYPE,
        PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS,
        PRODUCT_TYPE_HEADER_SEARCH_PATHS,
        PRODUCT_TYPE_LIBRARY_SEARCH_PATHS,
        PRODUCT_TYPE_SWIFT_INCLUDE_PATHS,
        PRODUCT_TYPE_SWIFT_STDLIB_TOOL_FLAGS,
        PRODUCT_TYPE_HAS_STUB_BINARY,
        WORKSPACE_DIR,
        PROJECT,
        PROJECT_CLASS_PREFIX,
        PROJECT_DIR,
        PROJECT_FILE_PATH,
        PROJECT_NAME,
        PROJECT_GUID,
        PROJECT_TEMP_DIR,
        PROVISIONING_PROFILE,
        PROVISIONING_PROFILE_DESTINATION_PATH,
        PROVISIONING_PROFILE_REQUIRED,
        PROVISIONING_PROFILE_SPECIFIER,
        PROVISIONING_PROFILE_SUPPORTED,
        PUBLIC_HEADERS_FOLDER_PATH,
        ProductResourcesDir,
        RC_ARCHS,
        RC_BASE_PROJECT_NAME,
        RC_ProjectName,
        RECORD_SYSTEM_HEADER_DEPENDENCIES_OUTSIDE_SYSROOT,
        RECURSIVE_SEARCH_PATHS_FOLLOW_SYMLINKS,
        MAKE_MERGEABLE,
        REEXPORTED_LIBRARY_NAMES,
        REEXPORTED_LIBRARY_PATHS,
        REEXPORTED_FRAMEWORK_NAMES,
        REMOVE_CVS_FROM_RESOURCES,
        REMOVE_GIT_FROM_RESOURCES,
        REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES,
        REMOVE_STATIC_EXECUTABLES_FROM_EMBEDDED_BUNDLES,
        REMOVE_HG_FROM_RESOURCES,
        REMOVE_SVN_FROM_RESOURCES,
        RESMERGER_SOURCES_FORK,
        RESOURCES_PLATFORM_NAME,
        RESOURCES_MINIMUM_DEPLOYMENT_TARGET,
        RESOURCES_TARGETED_DEVICE_FAMILY,
        RESOURCE_FLAG,
        RETAIN_RAW_BINARIES,
        REZ_COLLECTOR_DIR,
        REZ_NO_AUTOMATIC_SEARCH_PATHS,
        REZ_OBJECTS_DIR,
        REZ_PREFIX_FILE,
        REZ_SEARCH_PATHS,
        RUN_CLANG_STATIC_ANALYZER,
        RUN_DOCUMENTATION_COMPILER,
        SKIP_BUILDING_DOCUMENTATION,
        RUN_SYMBOL_GRAPH_EXTRACT,
        SYSTEM_EXTENSIONS_FOLDER_PATH,
        RUN_SWIFT_ABI_CHECKER_TOOL,
        RUN_SWIFT_ABI_CHECKER_TOOL_DRIVER,
        RUN_SWIFT_ABI_GENERATION_TOOL,
        SCRIPTS_FOLDER_PATH,
        SDKROOT,
        SDKDB_TO_SYMGRAPH_EXEC,
        SDK_DIR,
        SDK_NAME,
        SDK_NAMES,
        SDK_PRODUCT_BUILD_VERSION,
        SDK_VARIANT,
        SDK_VERSION,
        SDK_VERSION_ACTUAL,
        SDK_VERSION_MAJOR,
        SDK_VERSION_MINOR,
        SDK_STAT_CACHE_PATH,
        SDK_STAT_CACHE_DIR,
        SDK_STAT_CACHE_ENABLE,
        SDK_STAT_CACHE_VERBOSE_LOGGING,
        SEPARATE_STRIP,
        SEPARATE_SYMBOL_EDIT,
        SHALLOW_BUNDLE,
        SHARED_FRAMEWORKS_FOLDER_PATH,
        SHARED_PRECOMPS_DIR,
        TEMP_SANDBOX_DIR,
        SHARED_SUPPORT_FOLDER_PATH,
        SKIP_INSTALL,
        SKIP_CLANG_STATIC_ANALYZER,
        SKIP_EMBEDDED_FRAMEWORKS_VALIDATION,
        SOURCE_ROOT,
        SPECIALIZATION_SDK_OPTIONS,
        SRCROOT,
        STRINGSDATA_DIR,
        STRINGS_FILE_INPUT_ENCODING,
        STRINGS_FILE_OUTPUT_ENCODING,
        STRINGS_FILE_OUTPUT_FILENAME,
        STRINGS_FILE_INFOPLIST_RENAME,
        STRIP_BITCODE_FROM_COPIED_FILES,
        STRIP_INSTALLED_PRODUCT,
        STRIP_PNG_TEXT,
        STRIP_STYLE,
        STRIP_SWIFT_SYMBOLS,
        STRIPFLAGS,
        SUPPORTED_DEVICE_FAMILIES,
        SUPPORTED_PLATFORMS,
        SUPPORTED_HOST_TARGETED_PLATFORMS,
        HOST_TARGETED_PLATFORM_NAME,
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD,
        SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD,
        SUPPORTS_MACCATALYST,
        SUPPORTS_ON_DEMAND_RESOURCES,
        SUPPORTS_TEXT_BASED_API,
        SWIFT_AUTOLINK_EXTRACT_OUTPUT_PATH,
        PLATFORM_REQUIRES_SWIFT_AUTOLINK_EXTRACT,
        PLATFORM_REQUIRES_SWIFT_MODULEWRAP,
        SWIFT_ABI_CHECKER_BASELINE_DIR,
        SWIFT_ABI_CHECKER_EXCEPTIONS_FILE,
        SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR,
        SWIFT_ACCESS_NOTES_PATH,
        SWIFT_ALLOW_INSTALL_OBJC_HEADER,
        __SWIFT_ALLOW_INSTALL_OBJC_HEADER_MESSAGE,
        SWIFT_COMPILATION_MODE,
        SWIFT_DEPENDENCY_REGISTRATION_MODE,
        SWIFT_DEPLOYMENT_TARGET,
        SWIFT_DEVELOPMENT_TOOLCHAIN,
        SWIFT_EMIT_LOC_STRINGS,
        SWIFT_EMIT_MODULE_INTERFACE,
        SWIFT_ENABLE_BATCH_MODE,
        SWIFT_ENABLE_INCREMENTAL_COMPILATION,
        SWIFT_ENABLE_LAYOUT_STRING_VALUE_WITNESSES,
        SWIFT_ENABLE_LIBRARY_EVOLUTION,
        SWIFT_USE_INTEGRATED_DRIVER,
        SWIFT_EAGER_MODULE_EMISSION_IN_WMO,
        SWIFT_ENABLE_EXPLICIT_MODULES,
        _SWIFT_EXPLICIT_MODULES_ALLOW_CXX_INTEROP,
        _SWIFT_EXPLICIT_MODULES_ALLOW_BEFORE_SWIFT_5,
        _EXPERIMENTAL_SWIFT_EXPLICIT_MODULES,
        SWIFT_ENABLE_BARE_SLASH_REGEX,
        SWIFT_ENABLE_EMIT_CONST_VALUES,
        SWIFT_ENABLE_OPAQUE_TYPE_ERASURE,
        SWIFT_EMIT_CONST_VALUE_PROTOCOLS,
        SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS,
        SWIFT_ENABLE_TESTABILITY,
        SWIFT_EXEC,
        SWIFT_FORCE_DYNAMIC_LINK_STDLIB,
        SWIFT_FORCE_STATIC_LINK_STDLIB,
        SWIFT_FORCE_SYSTEM_LINK_STDLIB,
        SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES,
        SWIFT_LOAD_BINARY_MACROS,
        SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS,
        SWIFT_INCLUDE_PATHS,
        SWIFT_INDEX_STORE_ENABLE,
        SWIFT_INDEX_STORE_PATH,
        SWIFT_INSTALL_OBJC_HEADER,
        SWIFT_INSTALLAPI_LAZY_TYPECHECK,
        SWIFT_LIBRARIES_ONLY,
        SWIFT_LIBRARY_LEVEL,
        SWIFT_LIBRARY_PATH,
        SWIFT_LTO,
        SWIFT_MODULE_ALIASES,
        SWIFT_WARNINGS_AS_WARNINGS_GROUPS,
        SWIFT_WARNINGS_AS_ERRORS_GROUPS,
        SWIFT_MODULE_NAME,
        SWIFT_MODULE_ONLY_ARCHS,
        SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET,
        SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET,
        SWIFT_MODULE_ONLY_TVOS_DEPLOYMENT_TARGET,
        SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET,
        SWIFT_OBJC_BRIDGING_HEADER,
        SWIFT_OBJC_INTERFACE_HEADER_NAME,
        SWIFT_OBJC_INTERFACE_HEADER_DIR,
        SWIFT_OBJC_INTEROP_MODE,
        SWIFT_OPTIMIZATION_LEVEL,
        SWIFT_PACKAGE_NAME,
        SWIFT_SYSTEM_INCLUDE_PATHS,
        PACKAGE_RESOURCE_BUNDLE_NAME,
        PACKAGE_RESOURCE_TARGET_KIND,
        SWIFT_PLATFORM_TARGET_PREFIX,
        USE_SWIFT_RESPONSE_FILE, // remove in rdar://53000820
        SWIFT_INSTALL_MODULE,
        SWIFT_INSTALL_MODULE_FOR_DEPLOYMENT,
        SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR,
        SWIFT_RESPONSE_FILE_PATH,
        SWIFT_STDLIB,
        SWIFT_STDLIB_TOOL,
        SWIFT_STDLIB_TOOL_FOLDERS_TO_SCAN,
        SWIFT_TARGET_TRIPLE,
        SWIFT_TARGET_TRIPLE_VARIANTS,
        SWIFT_TOOLS_DIR,
        SWIFT_UNEXTENDED_MODULE_MAP_PATH,
        SWIFT_UNEXTENDED_INTERFACE_HEADER_PATH,
        SWIFT_UNEXTENDED_VFS_OVERLAY_PATH,
        SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION,
        SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME,
        SWIFT_USER_MODULE_VERSION,
        SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION,
        SWIFT_VERSION,
        EFFECTIVE_SWIFT_VERSION,
        SWIFT_WHOLE_MODULE_OPTIMIZATION,
        SWIFT_ENABLE_COMPILE_CACHE,
        SWIFT_ENABLE_PREFIX_MAPPING,
        SWIFT_OTHER_PREFIX_MAPPINGS,
        SYMBOL_GRAPH_EXTRACTOR_MODULE_NAME,
        SYMBOL_GRAPH_EXTRACTOR_OUTPUT_DIR,
        SYMBOL_GRAPH_EXTRACTOR_SEARCH_PATHS,
        SYMROOT,
        SYSTEM_ADMIN_APPS_DIR,
        SYSTEM_APPS_DIR,
        SYSTEM_CORE_SERVICES_DIR,
        SYSTEM_DEMOS_DIR,
        SYSTEM_DEVELOPER_APPS_DIR,
        SYSTEM_DEVELOPER_BIN_DIR,
        SYSTEM_DEVELOPER_DEMOS_DIR,
        SYSTEM_DEVELOPER_DIR,
        SYSTEM_DEVELOPER_DOC_DIR,
        SYSTEM_DEVELOPER_EXECUTABLES_DIR,
        SYSTEM_DEVELOPER_GRAPHICS_TOOLS_DIR,
        SYSTEM_DEVELOPER_JAVA_TOOLS_DIR,
        SYSTEM_DEVELOPER_PERFORMANCE_TOOLS_DIR,
        SYSTEM_DEVELOPER_RELEASENOTES_DIR,
        SYSTEM_DEVELOPER_TOOLS,
        SYSTEM_DEVELOPER_TOOLS_DOC_DIR,
        SYSTEM_DEVELOPER_TOOLS_RELEASENOTES_DIR,
        SYSTEM_DEVELOPER_USR_DIR,
        SYSTEM_DEVELOPER_UTILITIES_DIR,
        SYSTEM_DOCUMENTATION_DIR,
        SYSTEM_FRAMEWORK_SEARCH_PATHS,
        SYSTEM_FRAMEWORK_SEARCH_PATHS_USE_FSYSTEM,
        SYSTEM_HEADER_SEARCH_PATHS,
        SYSTEM_LIBRARY_DIR,
        SYSTEM_LIBRARY_EXECUTABLES_DIR,
        SYSTEM_PREFIX,
        SigningCert,
        TapiFileListPath,
        TAPI_DYLIB_INSTALL_NAME,
        TAPI_ENABLE_MODULES,
        TAPI_ENABLE_PROJECT_HEADERS,
        TAPI_USE_SRCROOT,
        TAPI_READ_DSYM,
        TAPI_RUNPATH_SEARCH_PATHS,
        TAPI_ENABLE_VERIFICATION_MODE,
        TAPI_EXEC,
        TAPI_EXTRACT_API_SEARCH_PATHS,
        TAPI_EXTRACT_API_OUTPUT_DIR,
        TAPI_EXTRACT_API_SDKDB_OUTPUT_PATH,
        TAPI_INPUTS,
        TAPI_HEADER_SEARCH_PATHS,
        TAPI_OUTPUT_PATH,
        TARGETED_DEVICE_FAMILY,
        TARGETNAME,
        TARGET_BUILD_DIR,
        TARGET_BUILD_SUBPATH,
        TARGET_DEVICE_OS_VERSION,
        TARGET_DEVICE_PLATFORM_NAME,
        TARGET_NAME,
        TARGET_TEMP_DIR,
        TEMP_DIR,
        TEMP_FILES_DIR,
        TEMP_FILE_DIR,
        TEMP_ROOT,
        TEST_BUILD_STYLE,
        TEST_FRAMEWORK_DEVELOPER_VARIANT_SUBPATH,
        TEST_FRAMEWORK_SEARCH_PATHS,
        TEST_PRIVATE_FRAMEWORK_SEARCH_PATHS,
        TEST_LIBRARY_SEARCH_PATHS,
        TEST_HOST,
        THIN_PRODUCT_STUB_BINARY,
        TOOLCHAINS,
        TOOLCHAIN_DIR,
        TREAT_MISSING_SCRIPT_PHASE_OUTPUTS_AS_ERRORS,
        TVOS_DEPLOYMENT_TARGET,
        TeamIdentifierPrefix,
        TempResourcesDir,
        UID,
        UNEXPORTED_SYMBOLS_FILE,
        UNINSTALLED_PRODUCTS_DIR,
        UNLOCALIZED_RESOURCES_FOLDER_PATH,
        UnlocalizedProductResourcesDir,
        UNSTRIPPED_PRODUCT,
        USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES,
        USER,
        USER_APPS_DIR,
        USER_HEADER_SEARCH_PATHS,
        USER_LIBRARY_DIR,
        USES_SWIFTPM_UNSAFE_FLAGS,
        USES_XCTRUNNER,
        USE_HEADERMAP,
        USE_HEADER_SYMLINKS,
        USE_HIERARCHICAL_LAYOUT_FOR_COPIED_ASIDE_PRODUCTS,
        VALIDATE_PLIST_FILES_WHILE_COPYING,
        VALIDATE_PRODUCT,
        VALIDATE_DEPENDENCIES,
        VALIDATE_DEVELOPMENT_ASSET_PATHS,
        VALID_ARCHS,
        VECTOR_SUFFIX,
        VERBOSE_PBXCP,
        VERSIONING_STUB,
        VERSIONING_SYSTEM,
        VERSIONPLIST_PATH,
        VERSIONS_FOLDER_PATH,
        VERSION_INFO_EXPORT_DECL,
        VERSION_INFO_FILE,
        VERSION_INFO_PREFIX,
        VERSION_INFO_STRING,
        VERSION_INFO_SUFFIX,
        ValidateForStore,
        WARNING_CFLAGS,
        WARNING_LDFLAGS,
        WATCHKIT_2_SUPPORT_FOLDER_PATH,
        WATCHKIT_EXTENSION_MAIN_LDFLAGS,
        WATCHKIT_EXTENSION_MAIN_LEGACY_SHIM_PATH,
        WATCHOS_DEPLOYMENT_TARGET,
        WARN_ON_VALID_ARCHS_USAGE,
        WRAPPER_EXTENSION,
        WRAPPER_NAME,
        XCODE_APP_SUPPORT_DIR,
        XCODE_INSTALL_PATH,
        XCODE_PRODUCT_BUILD_VERSION,
        XCODE_VERSION_ACTUAL,
        XCODE_VERSION_MAJOR,
        XCODE_VERSION_MINOR,
        XCSTRINGS_LANGUAGES_TO_COMPILE,
        XCTRUNNER_PATH,
        XCTRUNNER_PRODUCT_NAME,
        SKIP_COPYING_TEST_FRAMEWORKS,
        XPCSERVICES_FOLDER_PATH,
        YACC,
        YACCFLAGS,
        YACC_GENERATED_FILE_STEM,
        _BUILDABLE_SERIALIZATION_KEY,
        _WRAPPER_CONTENTS_DIR,
        _WRAPPER_PARENT_PATH,
        _WRAPPER_RESOURCES_DIR,
        __INPUT_FILE_LIST_PATH__,
        __ARCHS__,
        __SWIFT_MODULE_ONLY_ARCHS__,
        arch,
        build_file_compiler_flags,
        value,
        variant,
        LLVM_TARGET_TRIPLE_OS_VERSION,
        LLVM_TARGET_TRIPLE_VENDOR,
        ENABLE_ON_DEMAND_RESOURCES,
        ASSET_PACK_FOLDER_PATH,
        EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE,
        WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES,
        ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS,
        ON_DEMAND_RESOURCES_PREFETCH_ORDER,
        ASSET_PACK_MANIFEST_URL_PREFIX,
        ENABLE_XOJIT_PREVIEWS,
        BUILD_ACTIVE_RESOURCES_ONLY,
        ENABLE_ONLY_ACTIVE_RESOURCES,
        ENABLE_PLAYGROUND_RESULTS
    ]

    /// Force initialization of entitlements macros.
    private static let allEntitlementsMacros = [
        RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES,
        RUNTIME_EXCEPTION_ALLOW_JIT,
        RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY,
        AUTOMATION_APPLE_EVENTS,
        RUNTIME_EXCEPTION_DEBUGGING_TOOL,
        RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION,
        RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION,
        ENABLE_APP_SANDBOX,
        ENABLE_RESOURCE_ACCESS_AUDIO_INPUT,
        ENABLE_RESOURCE_ACCESS_BLUETOOTH,
        ENABLE_RESOURCE_ACCESS_CALENDARS,
        ENABLE_RESOURCE_ACCESS_CAMERA,
        ENABLE_RESOURCE_ACCESS_CONTACTS,
        ENABLE_RESOURCE_ACCESS_LOCATION,
        ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY,
        ENABLE_RESOURCE_ACCESS_PRINTING,
        ENABLE_RESOURCE_ACCESS_USB,
        ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER,
        ENABLE_FILE_ACCESS_PICTURE_FOLDER,
        ENABLE_FILE_ACCESS_MUSIC_FOLDER,
        ENABLE_FILE_ACCESS_MOVIES_FOLDER,
        ENABLE_INCOMING_NETWORK_CONNECTIONS,
        ENABLE_OUTGOING_NETWORK_CONNECTIONS,
        ENABLE_USER_SELECTED_FILES,
    ]

    /// Force initialization of Info.plist macros.
    private static let allInfoPlistMacros = [
        // Info.plist Keys - General
        INFOPLIST_KEY_CFBundleDisplayName,
        INFOPLIST_KEY_LSApplicationCategoryType,
        INFOPLIST_KEY_NSHumanReadableCopyright,
        INFOPLIST_KEY_NSPrincipalClass,

        // Info.plist Keys - Usage Descriptions
        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption,
        INFOPLIST_KEY_ITSEncryptionExportComplianceCode,
        INFOPLIST_KEY_NFCReaderUsageDescription,
        INFOPLIST_KEY_NSAppleEventsUsageDescription,
        INFOPLIST_KEY_NSAppleMusicUsageDescription,
        INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription,
        INFOPLIST_KEY_NSBluetoothPeripheralUsageDescription,
        INFOPLIST_KEY_NSBluetoothWhileInUseUsageDescription,
        INFOPLIST_KEY_NSCalendarsUsageDescription,
        INFOPLIST_KEY_NSCameraUsageDescription,
        INFOPLIST_KEY_NSContactsUsageDescription,
        INFOPLIST_KEY_NSDesktopFolderUsageDescription,
        INFOPLIST_KEY_NSDocumentsFolderUsageDescription,
        INFOPLIST_KEY_NSDownloadsFolderUsageDescription,
        INFOPLIST_KEY_NSFaceIDUsageDescription,
        INFOPLIST_KEY_NSFallDetectionUsageDescription,
        INFOPLIST_KEY_NSFileProviderDomainUsageDescription,
        INFOPLIST_KEY_NSFileProviderPresenceUsageDescription,
        INFOPLIST_KEY_NSFocusStatusUsageDescription,
        INFOPLIST_KEY_NSGKFriendListUsageDescription,
        INFOPLIST_KEY_NSHealthClinicalHealthRecordsShareUsageDescription,
        INFOPLIST_KEY_NSHealthShareUsageDescription,
        INFOPLIST_KEY_NSHealthUpdateUsageDescription,
        INFOPLIST_KEY_NSHomeKitUsageDescription,
        INFOPLIST_KEY_NSIdentityUsageDescription,
        INFOPLIST_KEY_NSLocalNetworkUsageDescription,
        INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription,
        INFOPLIST_KEY_NSLocationAlwaysUsageDescription,
        INFOPLIST_KEY_NSLocationTemporaryUsageDescription,
        INFOPLIST_KEY_NSLocationUsageDescription,
        INFOPLIST_KEY_NSLocationWhenInUseUsageDescription,
        INFOPLIST_KEY_NSMicrophoneUsageDescription,
        INFOPLIST_KEY_NSMotionUsageDescription,
        INFOPLIST_KEY_NSNearbyInteractionAllowOnceUsageDescription,
        INFOPLIST_KEY_NSNearbyInteractionUsageDescription,
        INFOPLIST_KEY_NSNetworkVolumesUsageDescription,
        INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription,
        INFOPLIST_KEY_NSPhotoLibraryUsageDescription,
        INFOPLIST_KEY_NSRemindersUsageDescription,
        INFOPLIST_KEY_NSRemovableVolumesUsageDescription,
        INFOPLIST_KEY_NSSensorKitPrivacyPolicyURL,
        INFOPLIST_KEY_NSSensorKitUsageDescription,
        INFOPLIST_KEY_NSSiriUsageDescription,
        INFOPLIST_KEY_NSSpeechRecognitionUsageDescription,
        INFOPLIST_KEY_NSSystemAdministrationUsageDescription,
        INFOPLIST_KEY_NSSystemExtensionUsageDescription,
        INFOPLIST_KEY_NSUserTrackingUsageDescription,
        INFOPLIST_KEY_NSVideoSubscriberAccountUsageDescription,
        INFOPLIST_KEY_NSVoIPUsageDescription,
        INFOPLIST_KEY_OSBundleUsageDescription,

        // Info.plist Keys - macOS
        INFOPLIST_KEY_LSBackgroundOnly,
        INFOPLIST_KEY_LSUIElement,
        INFOPLIST_KEY_NSMainNibFile,
        INFOPLIST_KEY_NSMainStoryboardFile,

        // Info.plist Keys - iOS and Derived Platforms
        INFOPLIST_KEY_UILaunchScreen_Generation,
        INFOPLIST_KEY_UILaunchStoryboardName,
        INFOPLIST_KEY_UIMainStoryboardFile,
        INFOPLIST_KEY_UIRequiredDeviceCapabilities,
        INFOPLIST_KEY_UISupportedInterfaceOrientations,
        INFOPLIST_KEY_UIUserInterfaceStyle,

        // Info.plist Keys - iOS
        INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace,
        INFOPLIST_KEY_NSSupportsLiveActivities,
        INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates,
        INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents,
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation,
        INFOPLIST_KEY_UIRequiresFullScreen,
        INFOPLIST_KEY_UIStatusBarHidden,
        INFOPLIST_KEY_UIStatusBarStyle,
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad,
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone,
        INFOPLIST_KEY_UISupportsDocumentBrowser,

        // Info.plist Keys - watchOS
        INFOPLIST_KEY_CLKComplicationPrincipalClass,
        __SKIP_INJECT_INFOPLIST_KEY_WKApplication,
        INFOPLIST_KEY_WKApplication,
        INFOPLIST_KEY_WKCompanionAppBundleIdentifier,
        INFOPLIST_KEY_WKExtensionDelegateClassName,
        INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp,
        INFOPLIST_KEY_WKWatchOnly,
        INFOPLIST_KEY_WKSupportsLiveActivityLaunchAttributeTypes,

        // Info.plist Keys - Metal
        INFOPLIST_KEY_MetalCaptureEnabled,

        // Info.plist Keys - Game Controller and Game Mode
        INFOPLIST_KEY_GCSupportsControllerUserInteraction,
        INFOPLIST_KEY_GCSupportsGameMode,

        // Info.plist Keys - Sticker Packs
        INFOPLIST_KEY_NSStickerSharingLevel,
    ]

    internal static func initialize() {
        precondition(!initialized)
        var seenConditionParameters = Set<String>()
        for conditionParameter in allBuiltinConditionParameters {
            precondition(!seenConditionParameters.contains(conditionParameter.name), "duplicate registration of condition parameter name: \(conditionParameter.name)")
            seenConditionParameters.insert(conditionParameter.name)
        }
        var seenMacros = Set<String>()
        for macro in allBuiltinMacros {
            precondition(!seenMacros.contains(macro.name), "duplicate registration of macro name: \(macro.name)")
            seenMacros.insert(macro.name)
        }

        for entitlementsMacro in allEntitlementsMacros {
            precondition(!seenMacros.contains(entitlementsMacro.name), "duplicate registration of entitlement macro: \(entitlementsMacro.name)")
            seenMacros.insert(entitlementsMacro.name)
        }

        for infoPlistMacro in allInfoPlistMacros {
            precondition(!seenMacros.contains(infoPlistMacro.name), "duplicate registration of Info.plist macro: \(infoPlistMacro.name)")
            seenMacros.insert(infoPlistMacro.name)
        }

        initialized = true
    }
}

/// A set of utility functions used primarily for the construction of command line arguments.
public extension BuiltinMacros {
    static func ifSet(_ macro: StringMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> [String]) -> [String] {
        let value = scope.evaluate(macro)
        if value.isEmpty { return [] }
        return fn(value)
    }

    static func ifSet(_ macro: StringMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> String) -> [String] {
        let value = scope.evaluate(macro)
        if value.isEmpty { return [] }
        return [fn(value)]
    }

    static func ifSet(_ macro: StringListMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> [String]) -> [String] {
        let value = scope.evaluate(macro)
        if value.isEmpty { return [] }
        return value.flatMap(fn)
    }

    static func ifSet(_ macro: StringListMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> String) -> [String] {
        let value = scope.evaluate(macro)
        if value.isEmpty { return [] }
        return value.compactMap(fn)
    }

    static func ifSet(_ macro:PathMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> [String]) -> [String] {
        let value = scope.evaluate(macro).str
        if value.isEmpty { return [] }
        return fn(value)
    }

    static func ifSet(_ macro: PathMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> String) -> [String] {
        let value = scope.evaluate(macro).str
        if value.isEmpty { return [] }
        return [fn(value)]
    }

    static func ifSet(_ macro: PathListMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> [String]) -> [String] {
        let value = scope.evaluate(macro)
        if value.isEmpty { return [] }
        return value.flatMap(fn)
    }

    static func ifSet(_ macro: PathListMacroDeclaration, in scope: MacroEvaluationScope, fn: (String) -> String) -> [String] {
        let value = scope.evaluate(macro)
        if value.isEmpty { return [] }
        return value.compactMap(fn)
    }

}

/// Enumeration macro type for tri-state booleans, typically used for warnings which can be set to "No", "Yes", or "Yes (Error)".
public enum BooleanWarningLevel: String, Equatable, Hashable, Serializable, EnumerationMacroType, Encodable {
    public static let defaultValue = BooleanWarningLevel.no

    case yesError = "YES_ERROR"
    case yes = "YES"
    case no = "NO"
}

/// Enumeration macro type for tri-state boolean value of whether the user has enabled Explicit module builds, disabled, or not set.
public enum SwiftEnableExplicitModulesSetting: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = SwiftEnableExplicitModulesSetting.notset

    case notset = "NOT_SET"
    case enabled = "YES"
    case disabled = "NO"
}

public enum SwiftDependencyRegistrationMode: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue: SwiftDependencyRegistrationMode = .makeStyleDependenciesSupplementedByScanner

    case makeStyleDependenciesSupplementedByScanner = "make-style"
    case swiftDependencyScannerOnly = "dependency-scanner"
    case verifySwiftDependencyScanner = "verify-swift-dependency-scanner"
}

public enum FineGrainedCachingSetting: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = FineGrainedCachingSetting.notset

    case notset = "NOT_SET"
    case enabled = "YES"
    case disabled = "NO"
}

public enum FineGrainedCachingVerificationSetting: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = FineGrainedCachingVerificationSetting.notset

    case notset = "NOT_SET"
    case enabled = "YES"
    case disabled = "NO"
}

/// Enumeration macro type for build settings granting file access.
public enum FileAccessMode: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = FileAccessMode.none

    case readOnly = "readonly"
    case readWrite = "readwrite"
    case none = ""
}

public enum ModuleVerifierKind: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue: ModuleVerifierKind = .external

    case builtin
    case external
    case both
}

public enum LinkerDriverChoice: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue: LinkerDriverChoice = .clang

    case clang
    case swiftc
}

/// Enumeration macro type for the value of the `INFOPLIST_KEY_LSApplicationCategoryType` build setting.
public enum ApplicationCategory: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = ApplicationCategory.none

    case none = ""
    case books = "public.app-category.books"
    case business = "public.app-category.business"
    case developerTools = "public.app-category.developer-tools"
    case education = "public.app-category.education"
    case entertainment = "public.app-category.entertainment"
    case finance = "public.app-category.finance"
    case foodAndDrink = "public.app-category.food-and-drink"
    case games = "public.app-category.games"
    case gamesAction = "public.app-category.action-games"
    case gamesAdventure = "public.app-category.adventure-games"
    case gamesArcade = "public.app-category.arcade-games"
    case gamesBoard = "public.app-category.board-games"
    case gamesCard = "public.app-category.card-games"
    case gamesCasino = "public.app-category.casino-games"
    case gamesDice = "public.app-category.dice-games"
    case gamesEducational = "public.app-category.educational-games"
    case gamesFamily = "public.app-category.family-games"
    case gamesKids = "public.app-category.kids-games"
    case gamesMusic = "public.app-category.music-games"
    case gamesPuzzle = "public.app-category.puzzle-games"
    case gamesRacing = "public.app-category.racing-games"
    case gamesRolePlaying = "public.app-category.role-playing-games"
    case gamesSimulation = "public.app-category.simulation-games"
    case gamesSports = "public.app-category.sports-games"
    case gamesStrategy = "public.app-category.strategy-games"
    case gamesTrivia = "public.app-category.trivia-games"
    case gamesWord = "public.app-category.word-games"
    case graphicsDesign = "public.app-category.graphics-design"
    case healthcareAndFitness = "public.app-category.healthcare-fitness"
    case lifestyle = "public.app-category.lifestyle"
    case magazinesAndNewspapers = "public.app-category.magazines-and-newspapers"
    case medical = "public.app-category.medical"
    case music = "public.app-category.music"
    case navigation = "public.app-category.navigation"
    case news = "public.app-category.news"
    case photography = "public.app-category.photography"
    case productivity = "public.app-category.productivity"
    case reference = "public.app-category.reference"
    case shopping = "public.app-category.shopping"
    case socialNetworking = "public.app-category.social-networking"
    case sports = "public.app-category.sports"
    case travel = "public.app-category.travel"
    case utilities = "public.app-category.utilities"
    case video = "public.app-category.video"
    case weather = "public.app-category.weather"
}

/// Enumeration macro type for the value of the `INFOPLIST_KEY_UIUserInterfaceStyle` build setting.
public enum UserInterfaceStyle: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = UserInterfaceStyle.automatic

    case automatic = "Automatic"
    case light = "Light"
    case dark = "Dark"
}

/// Enumeration macro type for the value of the `INFOPLIST_KEY_UIStatusBarStyle` build setting.
public enum StatusBarStyle: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = StatusBarStyle.defaultStyle

    case defaultStyle = "UIStatusBarStyleDefault"
    case lightContent = "UIStatusBarStyleLightContent"
    case darkContent = "UIStatusBarStyleDarkContent"
    case blackTranslucent = "UIStatusBarStyleBlackTranslucent"
    case blackOpaque = "UIStatusBarStyleBlackOpaque"
}

/// Enumeration macro type for the value of the `INFOPLIST_KEY_NSStickerSharingLevel` build setting.
public enum StickerSharingLevel: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = StickerSharingLevel.noSharing

    case noSharing = ""
    case messages = "Messages"
    case os = "OS"
}

/// Enumeration macro type for the value of the `ENTITLEMENTS_DESTINATION` build setting.
public enum EntitlementsDestination: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = EntitlementsDestination.none

    case codeSignature = "Signature"
    case entitlementsSection = "__entitlements"
    case none = ""
}

/// The target kind of package resources. This helps us conditionalize some task construction related to resources files for package targets.
public enum PackageResourceTargetKind: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = PackageResourceTargetKind.none

    /// The target is not a package target.
    case none

    /// The target is a regular package target (library, executable, test, etc). We most likely want to avoid performing compilation tasks of resource files in such targets because resources go in the associated bundle target.
    case regular

    /// The target is a package resource target which only contains resource files. We skip tasks that generate code for such targets.
    case resource
}

public enum LTOSetting: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue: LTOSetting = .no

    /// Full LTO
    case yes = "YES"
    /// Thin LTO
    case yesThin = "YES_THIN"
    /// No LTO
    case no = "NO"
}

public enum StripStyle: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = Self.all

    case all
    case nonGlobal = "non-global"
    case debugging
}

public enum MergedBinaryType: String, Equatable, Hashable, EnumerationMacroType {
    public static let defaultValue = Self.none

    case none
    case automatic
    case manual
}

public import SWBUtil

extension Diagnostic.Location {
    public static func buildSetting(_ macro: MacroDeclaration) -> Diagnostic.Location {
        return .buildSettings([macro])
    }

    public static func buildSettings(_ macros: [MacroDeclaration]) -> Diagnostic.Location {
        return .buildSettings(names: macros.map { $0.name })
    }
}

extension BuildVersion.Platform {
    public func deploymentTargetSettingName(infoLookup: (any PlatformInfoLookup)?) -> String {
        guard let infoProvider = infoLookup?.lookupPlatformInfo(platform: self),
              let dtsn = infoProvider.deploymentTargetSettingName else {
            fatalError("Mach-O based platforms must provide a deployment target setting name")
        }
        return dtsn
    }
}
