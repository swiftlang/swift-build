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

#if canImport(System)
    import struct System.FilePath
#else
    import struct SystemPackage.FilePath
#endif

import struct Foundation.Data
import class Foundation.JSONEncoder
import class Foundation.JSONDecoder

import SWBUtil

// MARK: Data structures

/// Hierarchy of data structures containing the dependencies for all targets in a build.
///
/// These structures can be encoded to and decoded from JSON.  The JSON is an API used by clients, and the data structures may become such an API eventually if we decide to share them directly with clients.
///
/// The names of properties in these structures are chosen mainly to be useful in the JSON file, so they may be a bit more verbose for use in Swift than they might be otherwise.
///
/// Presently the main way to instantiate these structures is to use `init(workspaceContext:buildRequest:buildRequestContext:operation:)`, which is defined below after the data structures.

/// The input and output dependencies for all targets in a build.
package struct BuildDependencyInfo: Codable {
    package init(targets: [BuildDependencyInfo.TargetDependencyInfo], errors: [String]) {
        self.targets = targets
        self.errors = errors
    }

    /// Structure describing the dependencies for a single target.  This includes a structure describing the identity of the target, and the declared inputs and outputs of the target.
    package struct TargetDependencyInfo: Codable {

        /// Structure describing the identity of a target.  This structure is `Hashable` so it can be used to determine if we've seen exactly this target before, and for testing purposes.
        package struct Target: Hashable {

            /// The name of the target.
            package let targetName: String

            /// The name of the project (for builds which use multiple Xcode projects).
            package let projectName: String?

            /// The name of the platform the target is building for.
            package let platformName: String?

        }

        /// Structure describing an input to a target.
        package struct Input: Hashable, Codable, Sendable {

            /// An input can be a framework or a library.
            package enum InputType: String, Codable, Sendable {
                case framework
                case library
            }

            /// The name reflects what information we have about the input in the project. Since Xcode often finds libraries and frameworks with search paths, we will have the the name of the input - or even only a stem if it's a `-l` option from `OTHER_LDFLAGS`. We may have an absolute path.
            package enum NameType: Hashable, Codable, Sendable {
                /// An absolute path, typically either because we found it in a build setting such as `OTHER_LDFLAGS`, or because some internal logic decided to link with an absolute path.
                case absolutePath(String)

                /// A file name being linked with a search path. This will be the whole name such as `Foo.framework` or `libFoo.dylib`.
                case name(String)

                /// The stem of a file being linked with a search path. For libraries this will be the part of the file name after `lib` and before the suffix. For other files this will be the file's base name without the suffix.
                ///
                /// Stems are often found after `-l` or `-framework` options in a build setting such as `OTHER_LDFLAGS`.
                case stem(String)

                /// Convenience method to return the associated value of the input as a String.  This is mainly for sorting purposes during tests to emit consistent results, since the names may be of different types.
                package var stringForm: String {
                    switch self {
                    case .absolutePath(let str):
                        return str
                    case .name(let str):
                        return str
                    case .stem(let str):
                        return str
                    }
                }

                /// Convenience method to return a string to use for sorting different names.
                package var sortableName: String {
                    switch self {
                    case .absolutePath(let str):
                        return FilePath(str).lastComponent.flatMap({ $0.string }) ?? str
                    case .name(let str):
                        return str
                    case .stem(let str):
                        return str
                    }
                }

            }

            /// For inputs which are linkages, we note whether we're linking using a search path or an absolute path.
            package enum LinkType: String, Codable, Sendable {
                case absolutePath
                case searchPath
            }

            /// The library type of the input. If we know that it's a dynamic or static library (usually from the file type of the input) then we note that. But for inputs from `-l` options in `OTHER_LDFLAGS`, we don't know the type.
            package enum LibraryType: String, Codable, Sendable {
                case dynamic
                case `static`
                case upward
                case unknown
            }

            package let inputType: InputType
            package let name: NameType
            package let linkType: LinkType
            package let libraryType: LibraryType

            package init(inputType: InputType, name: NameType, linkType: LinkType, libraryType: LibraryType) {
                self.inputType = inputType
                self.name = name
                self.linkType = linkType
                self.libraryType = libraryType
            }

        }

        package enum Dependency: Hashable, Codable, Sendable, Comparable {
            case `import`(name: String, accessLevel: AccessLevel, optional: Bool)
            case include(path: String)

            public static func < (lhs: Self, rhs: Self) -> Bool {
                switch lhs {
                case .import(let lhsName, let lhsAccessLevel, _):
                    switch rhs {
                    case .import(let rhsName, let rhsAccessLevel, _):
                        if lhsName == rhsName {
                            return lhsAccessLevel < rhsAccessLevel
                        } else {
                            return lhsName < rhsName
                        }
                    case .include: return false
                    }
                case .include(let lhsPath):
                    switch rhs {
                    case .import: return true
                    case .include(let rhsPath):
                        return lhsPath < rhsPath
                    }
                }
            }
        }

        package enum AccessLevel: String, Hashable, Codable, Sendable, Comparable {
            case Private = "private"
            case Package = "package"
            case Public = "public"

            public static func < (lhs: Self, rhs: Self) -> Bool {
                switch lhs {
                case .Private:
                    return true
                case .Public:
                    return false
                case .Package:
                    return rhs == .Public
                }
            }
        }

        /// The identifying information of the target.
        package let target: Target

        /// List of input files being used by the target.
        /// - remark: Presently this is the list of linked libraries and frameworks, often located using search paths.
        package let inputs: [Input]

        /// List of paths of outputs in the `DSTROOT` which we report.
        /// - remark: Presently this contains only the product of the target, if any.
        package let outputPaths: [String]

        package let dependencies: [Dependency]
    }

    /// Info for all of the targets in the build.
    package let targets: [TargetDependencyInfo]

    /// Any errors detected in collecting the dependency info for the build.
    package let errors: [String]

}

// MARK: Encoding and decoding

extension BuildDependencyInfo.TargetDependencyInfo {

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target.targetName, forKey: .targetName)
        try container.encode(target.projectName, forKey: .projectName)
        try container.encode(target.platformName, forKey: .platformName)
        if !inputs.isEmpty {
            // Sort the inputs by name, stem, or last path component.
            let sortedInputs = inputs.sorted(by: { $0.name.sortableName < $1.name.sortableName })
            try container.encode(sortedInputs, forKey: .inputs)
        }
        if !outputPaths.isEmpty {
            try container.encode(outputPaths.sorted(), forKey: .outputPaths)
        }
        if !dependencies.isEmpty {
            try container.encode(dependencies.sorted(), forKey: .dependencies)
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targetName = try container.decode(String.self, forKey: .targetName)
        let projectName = try container.decode(String.self, forKey: .projectName)
        let platformName = try container.decode(String.self, forKey: .platformName)
        self.target = Target(targetName: targetName, projectName: projectName, platformName: platformName)
        self.inputs = try container.decodeIfPresent([Input].self, forKey: .inputs) ?? []
        self.outputPaths = try container.decodeIfPresent([String].self, forKey: .outputPaths) ?? []
        self.dependencies = try container.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case targetName
        case projectName
        case platformName
        case inputs
        case outputPaths
        case dependencies
    }

    package init(targetName: String, projectName: String?, platformName: String?, inputs: [Input], outputPaths: [String], dependencies: [Dependency]) {
        self.target = Target(targetName: targetName, projectName: projectName, platformName: platformName)
        self.inputs = inputs
        self.outputPaths = outputPaths
        self.dependencies = dependencies
    }

}

extension BuildDependencyInfo.TargetDependencyInfo.Input {

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputType, forKey: .inputType)
        try container.encode(name, forKey: .name)
        try container.encode(linkType, forKey: .linkType)
        try container.encode(libraryType, forKey: .libraryType)
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputType = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.InputType.self, forKey: .inputType)
        self.name = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.NameType.self, forKey: .name)
        self.linkType = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.LinkType.self, forKey: .linkType)
        self.libraryType = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.LibraryType.self, forKey: .libraryType)
    }

    private enum CodingKeys: String, CodingKey {
        case inputType
        case name
        case linkType
        case libraryType
    }

}

extension BuildDependencyInfo.TargetDependencyInfo.Input.NameType {

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absolutePath(let path):
            try container.encode(path, forKey: .path)
        case .name(let name):
            try container.encode(name, forKey: .name)
        case .stem(let stem):
            try container.encode(stem, forKey: .stem)
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .path) {
            self = .absolutePath(path)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self = .name(name)
        } else if let stem = try container.decodeIfPresent(String.self, forKey: .stem) {
            self = .stem(stem)
        } else {
            throw StubError.error("unknown type for input name")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case name
        case stem
    }

}

// MARK: Custom string definitions for better debugging

extension BuildDependencyInfo.TargetDependencyInfo.Target: CustomStringConvertible {
    package var description: String {
        return "\(type(of: self))<target=\(targetName):project=\(projectName == nil ? "nil" : projectName!):platform=\(platformName == nil ? "nil" : platformName!)>"
    }
}

extension BuildDependencyInfo.TargetDependencyInfo.Input: CustomStringConvertible {
    package var description: String {
        return "\(type(of: self))<\(inputType):\(name):linkType=\(linkType):libraryType=\(libraryType)>"
    }
}

extension BuildDependencyInfo.TargetDependencyInfo.Input.NameType: CustomStringConvertible {
    package var description: String {
        switch self {
        case .absolutePath(let path):
            return "path=\(path).str"
        case .name(let name):
            return "name=\(name)"
        case .stem(let stem):
            return "stem=\(stem)"
        }
    }
}
