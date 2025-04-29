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

import Foundation
import SWBProtocol
import SWBUtil

extension ProjectModel {
    public struct BuildSettings: Sendable, Hashable {
        public enum SingleValueSetting: String, CaseIterable, Sendable, Equatable, Codable {
            case APPLICATION_EXTENSION_API_ONLY
            case BUILT_PRODUCTS_DIR
            case CLANG_CXX_LANGUAGE_STANDARD
            case CLANG_ENABLE_MODULES
            case CLANG_DISABLE_CXX_MODULES
            case CLANG_ENABLE_OBJC_ARC
            case CODE_SIGNING_REQUIRED
            case CODE_SIGN_IDENTITY
            case COMBINE_HIDPI_IMAGES
            case COPY_PHASE_STRIP
            case DEBUG_INFORMATION_FORMAT
            case DEFINES_MODULE
            case DRIVERKIT_DEPLOYMENT_TARGET
            case DYLIB_INSTALL_NAME_BASE
            case EMBEDDED_CONTENT_CONTAINS_SWIFT
            case ENABLE_NS_ASSERTIONS
            case ENABLE_TESTABILITY
            case ENABLE_TESTING_SEARCH_PATHS
            case ENTITLEMENTS_REQUIRED
            case EXECUTABLE_PREFIX
            case GENERATE_INFOPLIST_FILE
            case GCC_C_LANGUAGE_STANDARD
            case GCC_OPTIMIZATION_LEVEL
            case GENERATE_MASTER_OBJECT_FILE
            case INFOPLIST_FILE
            case IPHONEOS_DEPLOYMENT_TARGET
            case KEEP_PRIVATE_EXTERNS
            case CLANG_COVERAGE_MAPPING_LINKER_ARGS
            case MACH_O_TYPE
            case MACOSX_DEPLOYMENT_TARGET
            case MODULEMAP_FILE
            case MODULEMAP_FILE_CONTENTS
            case MODULEMAP_PATH
            case MODULE_CACHE_DIR
            case ONLY_ACTIVE_ARCH
            case PACKAGE_RESOURCE_BUNDLE_NAME
            case PACKAGE_RESOURCE_TARGET_KIND
            case PRODUCT_BUNDLE_IDENTIFIER
            case PRODUCT_MODULE_NAME
            case PRODUCT_NAME
            case PROJECT_NAME
            case SDKROOT
            case SDK_VARIANT
            case SKIP_INSTALL
            case INSTALL_PATH
            case SUPPORTS_MACCATALYST
            case SWIFT_SERIALIZE_DEBUGGING_OPTIONS
            case SWIFT_INSTALL_OBJC_HEADER
            case SWIFT_OBJC_INTERFACE_HEADER_NAME
            case SWIFT_OBJC_INTERFACE_HEADER_DIR
            case SWIFT_OPTIMIZATION_LEVEL
            case SWIFT_VERSION
            case TARGET_NAME
            case TARGET_BUILD_DIR
            case TVOS_DEPLOYMENT_TARGET
            case USE_HEADERMAP
            case USES_SWIFTPM_UNSAFE_FLAGS
            case WATCHOS_DEPLOYMENT_TARGET
            case XROS_DEPLOYMENT_TARGET
            case _IOS_DEPLOYMENT_TARGET
            case MARKETING_VERSION
            case CURRENT_PROJECT_VERSION
            case SWIFT_EMIT_MODULE_INTERFACE
            case GENERATE_RESOURCE_ACCESSORS
            case BUILD_LIBRARY_FOR_DISTRIBUTION
            case BUILD_PACKAGE_FOR_DISTRIBUTION
            case COMPILER_WORKING_DIRECTORY
            case COREML_CODEGEN_LANGUAGE
            case COREML_COMPILER_CONTAINER
            case EXECUTABLE_NAME
            case GENERATE_EMBED_IN_CODE_ACCESSORS
            case INSTALLAPI_COPY_PHASE
            case INSTALLHDRS_COPY_PHASE
            case IS_ZIPPERED
            case PACKAGE_REGISTRY_SIGNATURE
            case PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME
            case SKIP_BUILDING_DOCUMENTATION
            case SKIP_CLANG_STATIC_ANALYZER
            case STRIP_INSTALLED_PRODUCT
            case SUPPORTS_TEXT_BASED_API
            case SUPPRESS_WARNINGS
            case SWIFT_ENABLE_BARE_SLASH_REGEX
            case SWIFT_INSTALL_MODULE
            case SWIFT_PACKAGE_NAME
            case SWIFT_USER_MODULE_VERSION
            case TAPI_DYLIB_INSTALL_NAME
            case TARGETED_DEVICE_FAMILY
            case LINKER_DRIVER
            case LD_WARN_DUPLICATE_LIBRARIES
        }

        public enum MultipleValueSetting: String, CaseIterable, Sendable, Hashable, Codable {
            case EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES
            case FRAMEWORK_SEARCH_PATHS
            case GCC_PREPROCESSOR_DEFINITIONS
            case HEADER_SEARCH_PATHS
            case LD_RUNPATH_SEARCH_PATHS
            case LIBRARY_SEARCH_PATHS
            case OTHER_CFLAGS
            case OTHER_CPLUSPLUSFLAGS
            case OTHER_LDFLAGS
            case OTHER_LDRFLAGS
            case OTHER_SWIFT_FLAGS
            case PRELINK_FLAGS
            case SPECIALIZATION_SDK_OPTIONS
            case SUPPORTED_PLATFORMS
            case SWIFT_ACTIVE_COMPILATION_CONDITIONS
            case SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES
            case SWIFT_MODULE_ALIASES
            case SWIFT_WARNINGS_AS_WARNINGS_GROUPS
            case SWIFT_WARNINGS_AS_ERRORS_GROUPS
        }

        public enum Declaration: String, Hashable, CaseIterable, Sendable {
            case ARCHS
            case GCC_PREPROCESSOR_DEFINITIONS
            case FRAMEWORK_SEARCH_PATHS
            case HEADER_SEARCH_PATHS
            case IPHONEOS_DEPLOYMENT_TARGET
            case OTHER_CFLAGS
            case OTHER_CPLUSPLUSFLAGS
            case OTHER_LDFLAGS
            case OTHER_SWIFT_FLAGS
            case SPECIALIZATION_SDK_OPTIONS
            case SWIFT_VERSION
            case SWIFT_ACTIVE_COMPILATION_CONDITIONS
        }

        public enum Platform: Hashable, CaseIterable, Sendable {
            case macOS
            case macCatalyst
            case iOS

            // Special case to support arm64e-only iOS app builds with SwiftPM dependencies. Don't use it for anything else!
            case _iOSDevice

            case tvOS
            case watchOS
            case xrOS

            case driverKit

            case linux
            case android
            case windows
            case wasi
            case openbsd
            case freebsd

            public var asConditionStrings: [String] {
                let filters = self.toPlatformFilter().map { (filter: ProjectModel.PlatformFilter) -> String in
                    if filter.environment.isEmpty {
                        return filter.platform
                    } else {
                        return "\(filter.platform)-\(filter.environment)"
                    }
                }.sorted()
                return ["__platform_filter=\(filters.joined(separator: ";"))"]
            }
        }

        public var platformSpecificSettings = [Platform: [Declaration: [String]]]()

        public init() {
            var settings: [Declaration: [String]] = [:]
            for declaration in Declaration.allCases {
                settings[declaration] = ["$(inherited)"]
            }

            for platform in Platform.allCases {
                platformSpecificSettings[platform] = settings
            }
        }

        private(set) var singleValueSettings: OrderedDictionary<String, String> = [:]
        private(set) var multipleValueSettings: OrderedDictionary<String, [String]> = [:]

        public subscript(_ setting: SingleValueSetting) -> String? {
            get { singleValueSettings[setting.rawValue] }
            set { singleValueSettings[setting.rawValue] = newValue }
        }

        public subscript(single setting: String) -> String? {
            get { singleValueSettings[setting] }
            set { singleValueSettings[setting] = newValue }
        }

        public subscript(_ setting: MultipleValueSetting) -> [String]? {
            get { multipleValueSettings[setting.rawValue] }
            set { multipleValueSettings[setting.rawValue] = newValue }
        }

        public subscript(multiple setting: String) -> [String]? {
            get { multipleValueSettings[setting] }
            set { multipleValueSettings[setting] = newValue }
        }
    }
}


public extension ProjectModel.BuildSettings.Platform {
    func toPlatformFilter() -> [ProjectModel.PlatformFilter] {
        var result: [ProjectModel.PlatformFilter] = []

        switch self {
        case .macOS:
            result.append(.init(platform: "macos"))

        case .macCatalyst:
            result.append(.init(platform: "ios", environment: "maccatalyst"))

        case .iOS:
            result.append(.init(platform: "ios"))
            result.append(.init(platform: "ios", environment: "simulator"))

        case ._iOSDevice:
            result.append(.init(platform: "ios"))

        case .tvOS:
            result.append(.init(platform: "tvos"))
            result.append(.init(platform: "tvos", environment: "simulator"))

        case .watchOS:
            result.append(.init(platform: "watchos"))
            result.append(.init(platform: "watchos", environment: "simulator"))

        case .xrOS:
            result.append(.init(platform: "xros"))
            result.append(.init(platform: "xros", environment: "simulator"))

        case .driverKit:
            result.append(.init(platform: "driverkit"))

        case .linux:
            result.append(.init(platform: "linux", environment: "gnu"))

        case .android:
            result.append(.init(platform: "linux", environment: "android"))
            result.append(.init(platform: "linux", environment: "androideabi"))

        case .windows:
            result.append(.init(platform: "windows", environment: "msvc"))

        case .wasi:
            result.append(.init(platform: "wasi"))

        case .openbsd:
            result.append(.init(platform: "openbsd"))

        case .freebsd:
            result.append(.init(platform: "freebsd"))
        }
        return result
    }
}

extension ProjectModel.BuildSettings: Codable {
    private struct StringKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(stringValue value: String) {
            self.stringValue = value
        }

        init(_ value: String) {
            self.stringValue = value
        }

        init?(intValue: Int) {
            assertionFailure("does not support integer keys")
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init()

        let container = try decoder.container(keyedBy: StringKey.self)

        // NOTE: unknown settings will be lost during decoding, as there is no way to tell
        // if they are a single or multiple value setting.

        for key in SingleValueSetting.allCases {
            if let value = try container.decodeIfPresent(String.self, forKey: StringKey(key.rawValue)) {
                self[key] = value
            }
        }
        for key in MultipleValueSetting.allCases {
            if let value = try container.decodeIfPresent([String].self, forKey: StringKey(key.rawValue)) {
                self[key] = value
            }
        }
        for platform in Platform.allCases {
            for condition in platform.asConditionStrings {
                for declaration in Declaration.allCases {
                    if let value = try container.decodeIfPresent([String].self, forKey: StringKey("\(declaration.rawValue)[\(condition)]")) {
                        self.platformSpecificSettings[platform, default: [:]][declaration] = value
                    }
                }
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: StringKey.self)

        for (key, value) in singleValueSettings {
            try container.encode(value, forKey: StringKey(key))
        }

        for (key, value) in multipleValueSettings {
            try container.encode(value, forKey: StringKey(key))
        }

        for (platformCondition, values) in platformSpecificSettings {
            for condition in platformCondition.asConditionStrings {
                for (key, value) in values {
                    // If `$(inherited)` is the only value, do not emit anything to the PIF.
                    if value == ["$(inherited)"] {
                        continue
                    }
                    try container.encode(value, forKey: StringKey("\(key.rawValue)[\(condition)]"))
                }
            }
        }
    }
}
