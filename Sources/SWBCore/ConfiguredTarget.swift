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

public import SWBUtil
import SWBProtocol

public final class ConfiguredTarget: Hashable, CustomStringConvertible, Serializable, Comparable, Sendable, Encodable {
    /// The build parameters to use for this target.
    public let parameters: BuildParameters

    /// The target to build.
    public let target: Target

    /// If true the `guid` string includes run destination information.
    ///
    /// This is utilized by the index build description to differentiate targets that have `SDKROOT` set (it's not 'auto'), so they don't need an override for SDKROOT and SDK_VARIANT, but are configured for multiple platforms and their `guid` needs be different.
    @_spi(BuildDescriptionSignatureComponents) public let specializeGuidForActiveRunDestination: Bool

    /// Create a new configured target instance.
    /// - parameter parameters: The build parameters the target is configured with.
    /// - parameter target: The target to be configured.
    /// - parameter specializeGuidForActiveRunDestination: If true the `guid` string includes run destination information. This is currently only used by the index build which configures the targets for multiple platforms.
    public init(parameters: BuildParameters, target: Target, specializeGuidForActiveRunDestination: Bool = false) {
        self.parameters = parameters
        self.target = target
        self.specializeGuidForActiveRunDestination = specializeGuidForActiveRunDestination
    }

    public func replacingTarget(_ target: Target) -> ConfiguredTarget {
        return ConfiguredTarget(parameters: parameters, target: target, specializeGuidForActiveRunDestination: specializeGuidForActiveRunDestination)
    }

    // FIXME: Change configuredTarget to use referential equality. This needs some kind of solution to the Target -> ConfiguredTarget problem, though.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(parameters)
        hasher.combine(target)
        hasher.combine(specializeGuidForActiveRunDestination)
    }

    public static func < (lhs: ConfiguredTarget, rhs: ConfiguredTarget) -> Bool {
        return lhs.guid < rhs.guid
    }

    public var description: String {
        // Collect the target's name and interesting components of the parameters to produce a description which can be used to identify different ConfiguredTargets which represent the same Target in the build (e.g., due to specialization).
        var components: [(key: String, value: String)] = [
            ("target", "\(target.name):\(target.guid)")
        ]
        let parameters: [String] = self.parameters.overrides.sorted(byKey: <).compactMap {
            if ["SDKROOT", "SDK_VARIANT"].contains($0.key) {
                return "\($0.key):\($0.value)"
            } else {
                return nil
            }
        }
        if !parameters.isEmpty {
            components.append(("parameters", parameters.joined(separator: "-")))
        }
        if specializeGuidForActiveRunDestination, let runDestination = self.parameters.activeRunDestination {
            var runDestString = runDestination.platform
            if let sdkVariant = runDestination.sdkVariant {
                runDestString += "+\(sdkVariant)"
            }
            components.append(("runDestination", runDestString))
        }

        let string = components.map({ "\($0.key): \($0.value)"}).joined(separator: " ")

        // Construct the description.
        return "<\(type(of: self)) \(string)>"
    }

    public struct GUID: Hashable, Sendable, Comparable, CustomStringConvertible {
        public let stringValue: String

        fileprivate init(id: String) {
            self.stringValue = id
        }

        public static func < (lhs: GUID, rhs: GUID) -> Bool {
            return lhs.stringValue < rhs.stringValue
        }

        public var description: String {
            stringValue
        }
    }

    /// An identifier that contributes to all task identifiers in order to disambiguate them.
    ///
    /// Note that making significant changes to the formatting of the `guid` will likely require updating quite a few tests.
    public var guid: GUID {
        var parameters: [String] = self.parameters.overrides.sorted(byKey: <).compactMap {
            if ["SDKROOT", "SDK_VARIANT"].contains($0.key) {
                return "\($0.key):\($0.value)"
            } else {
                return nil
            }
        }
        if specializeGuidForActiveRunDestination {
            let discriminator = self.parameters.activeRunDestination.map{ "\($0.platform)-\($0.sdkVariant ?? "")" } ?? ""
            parameters.append(discriminator)
        }
        return .init(id: ["target", target.name, target.guid, parameters.joined(separator: ":")].joined(separator: "-"))
    }

    // Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        guard let delegate = serializer.delegate as? (any ConfiguredTargetSerializerDelegate) else { fatalError("delegate must be a ConfiguredTargetSerializerDelegate") }

        serializer.beginAggregate(4)

        // Serialize the target's GUID.
        serializer.serialize(target.guid)
        serializer.serialize(specializeGuidForActiveRunDestination)

        // Make sure each build parameters struct is serialized only once.
        if let index = delegate.buildParametersIndexes[parameters] {
            // We already have an index into the build parameters list, so serialize it.
            serializer.serialize(1)         // Placeholder indicating the next element is an index
            serializer.serialize(index)
        }
        else {
            // These parameters have not been serialized before, so serialize them and add them to our delegate's index map.
            serializer.serialize(0)         // Placeholder indicating the next element is a serialized BuildParameters
            serializer.serialize(parameters)
            delegate.buildParametersIndexes[parameters] = delegate.currentBuildParametersIndex
            delegate.currentBuildParametersIndex += 1
        }

        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        guard let delegate = deserializer.delegate as? (any ConfiguredTargetDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a ConfiguredTargetDeserializerDelegate") }

        try deserializer.beginAggregate(4)

        // Deserialize the target's GUID and look it up via the delegate.
        let guid: String = try deserializer.deserialize()
        guard let target = delegate.workspace.target(for: guid) else { throw DeserializerError.deserializationFailed("Could not look up target for guid '\(guid)' in workspace '\(delegate.workspace)'") }
        self.target = target

        self.specializeGuidForActiveRunDestination = try deserializer.deserialize()

        // Deserialize the build parameters by deserializing it if we haven't seen it before, or by looking it up via the delegate if we have.
        let placeholder: Int = try deserializer.deserialize()
        switch placeholder {
        case 0:
            // Deserialize the parameters and add them to the delegate.
            let parameters: BuildParameters = try deserializer.deserialize()
            delegate.buildParameters.append(parameters)
            self.parameters = parameters
        case 1:
            // Look up the parameters from our delegate.
            let index: Int = try deserializer.deserialize()
            guard index >= 0 && index < delegate.buildParameters.count else { throw DeserializerError.deserializationFailed("BuildParameters index \(index) in ConfiguredTarget is out of range (\(delegate.buildParameters.count) parameters)") }
            self.parameters = delegate.buildParameters[index]
        default:
            throw DeserializerError.deserializationFailed("BuildParameters placeholder was unexpected value '\(placeholder)'")
        }
    }

    public static func ==(lhs: ConfiguredTarget, rhs: ConfiguredTarget) -> Bool {
        // Fast path common case.
        //
        // FIXME: We key on this a lot -- we need to move this to using reference equality: <rdar://problem/28948909> Change ConfiguredTarget to use reference equality
        if lhs === rhs { return true }

        return (lhs.target == rhs.target && lhs.parameters == rhs.parameters && lhs.specializeGuidForActiveRunDestination == rhs.specializeGuidForActiveRunDestination)
    }
}

/// A delegate which must be used to serialize a `ConfiguredTarget`.
public protocol ConfiguredTargetSerializerDelegate: SerializerDelegate {

    // Properties to make sure each build parameters struct gets serialized only once.

    var currentBuildParametersIndex: Int { get set }
    var buildParametersIndexes: [BuildParameters: Int] { get set }

    // Properties to make sure each configured target gets serialized only once.

    var currentConfiguredTargetIndex: Int { get set }
    var configuredTargetIndexes: [ConfiguredTarget: Int] { get set }
}

/// A delegate which must be used to deserialize a `ConfiguredTarget`.
public protocol ConfiguredTargetDeserializerDelegate: AnyObject, DeserializerDelegate {
    /// The workspace in which to look up targets being deserialized.
    var workspace: Workspace { get }

    /// A list of `BuildParameters` built up during deserialization so that after one has been deserialized, later references can be looked up by index based on the order they were deserialized.
    var buildParameters: [BuildParameters] { get set }

    /// A list of `ConfigureTarget`s built up during deserialization so that after one has been deserialized, later references can be looked up by index based on the order they were deserialized.
    var configuredTargets: [ConfiguredTarget] { get set }
}
