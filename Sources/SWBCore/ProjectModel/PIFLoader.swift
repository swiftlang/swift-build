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
public import SWBProtocol
public import SWBMacro
import Foundation

enum PIFLoadingError: Error {
    /// Indicates a general PIF object decoding error.
    case invalidObject(message: String)

    /// Indicates an invalid top-level PIF object.
    case invalidObjectType(typeName: String)

    /// Indicates that an unloaded PIF object was expected to be available for loading, but was not.
    case unavailableObject(key: PIFObjectReference)

    /// Indicates an object that wasn't needed was sent to the incremental PIF loader.
    case nonRequiredObject(key: PIFObjectReference)

    /// Indicates that a referenced object was not sent to the incremental PIF loader.
    case missingObject(key: PIFObjectReference)

    /// Indicates that multiple referenced objects were not sent to the incremental PIF loader.
    case missingObjects(keys: Set<PIFObjectReference>)

    /// Indicates a duplicate registration error for the specified GUID.
    case guidAlreadyRegistered(type: PIFLoader.Type, guid: String)

    /// Indicates multiple objects of the same type had the same signature.
    case conflictingSignatures(type: PIFObjectType, signature: String)

    /// Indicates that there is a mismatch between the supported PIF format version between the client and service.
    case incompatiblePIFVersion(client: PIFSchemaVersion, service: PIFSchemaVersion)

    /// Indicates there is a problem determining the PIF schema version.
    case missingPIFVersionFromSignature(signature: String)

    /// Indicates there is a problem with the composition of targets and the location of package products.
    case incompatiblePackageTargetProject(target: String)
}

extension PIFLoadingError: CustomStringConvertible {
    var description: String {
        switch self {
        case let .invalidObject(message):
            return message
        case let .invalidObjectType(typeName):
            return "unexpected top-level object type: '\(typeName)'"
        case let .unavailableObject(key):
            return "Expected unloaded PIF object with key '\(key)' to be available for loading"
        case let .nonRequiredObject(key):
            return "object \(key) was added, but not required"
        case let .missingObject(key):
            return "object \(key) was referenced, but is missing"
        case let .missingObjects(keys):
            return "objects \(keys.map { String(describing: $0) }.sorted().joined(separator: ", ")) was referenced, but is missing"
        case let .guidAlreadyRegistered(type, guid):
            return "\(type): GUID '\(guid)' has already been registered"
        case let .conflictingSignatures(type, signature):
            return "multiple \(type.rawValue)s with identical signature: \(signature)"
        case let .incompatiblePIFVersion(client, service):
            return "mismatch between client and service versions: \(client) vs. \(service)"
        case let .missingPIFVersionFromSignature(signature):
            return "no PIF version found in signature: \(signature)"
        case let .incompatiblePackageTargetProject(target):
            return "package target '\(target)' must be contained within a package project"
        }
    }
}

/// A PIF value, in one of the two supported encodings.
//
// FIXME: Eliminate the legacy encoding so we can get rid of this.
public enum EncodedPIFValue {
    case json(ProjectModelItemPIF)
    case binary(ByteString)

    var isBinary: Bool {
        switch self {
        case .json: return false
        case .binary: return true
        }
    }
}

/// A reference to a PIFObject.
struct PIFObjectReference: Hashable {
    /// The type of a PIF object signature.
    typealias Signature = String

    /// The signature of the object.
    let signature: Signature

    /// The type of the object.
    let type: PIFObjectType
}

/// Based on the PIF signature, the encoded PIF schema version is parsed out.
@_spi(Testing) public func parsePIFVersion(_ signature: String) throws -> PIFSchemaVersion {
    // The version is derived from the signature, which starts with: "WORKSPACE@v%d_". The "WORKSPACE" string should be ignored as there are other variants!
    guard let vers = Int(signature.split("_").0.split("v").1) else {
        // NOTE: Once rdar://54261777 is implemented, this can be a more stringent test. Until then, assume the latest version .
        // throw PIFLoadingError.missingPIFVersionFromSignature(signature: signature)
        return SWBProtocol.PIFObject.supportedPIFEncodingSchemaVersion
    }
    return vers
}


/// A top-level object which can be represented independently in the PIF format.
///
/// These objects represent the granularity at which the PIF can be incrementally loaded or replaced.
protocol PIFObject: Sendable {
    typealias Signature = PIFObjectReference.Signature

    /// The PIF object type.
    static var pifType: PIFObjectType { get }

    /// The signature of the object.
    ///
    /// The signature represents a unique signature which is changed any time the object is modified with respect to its containing object. That is to say, a different containing object is allowed to have an object of the same type with the same signature, but different values.
    ///
    /// The caveats above are not ideal (we would like to have completely unique signatures), but allow us to more efficiently implement the transfer mechanism for objects for which we do not have an easy way to performantly generate a unique signature. See the Xcode implementation of target signatures to understand why this is an important distinction.
    var signature: Signature { get }

    /// Extract the list of PIF objects referenced from the given PIF data.
    ///
    /// - Returns: The list of referenced objects by signature and type.
    static func referencedObjects(for data: EncodedPIFValue) throws -> [PIFObjectReference]

    /// Create an object from the given data.
    static func construct(from data: EncodedPIFValue, signature: PIFObjectReference.Signature, loader: PIFLoader) throws -> Self
}

/// A protocol for providing loaded PIF objects.
///
/// This may be backed by previously loaded instances, or it may always load the items via the provided `loader`.
protocol PIFObjectProvider {
    /// Fetch the object with the given type and signature.
    func fetchObject<T: PIFObject>(signature: PIFObject.Signature, type: T.Type, loader: PIFLoader) throws -> T
}

extension PIFObjectType {
    /// The set of known PIF object types.
    var objectType: any PIFObject.Type {
        switch self {
        case .workspace:
            return Workspace.self
        case .project:
            return Project.self
        case .target:
            return Target.self
        }
    }
}

/// Helper class for loading PIF data into complete objects.
public final class PIFLoader {
    /// The object provider.
    let provider: any PIFObjectProvider

    /// The namespace for user build settings.  A new one is created for each `PIFLoader`, and ownership is transferred to the loaded `Workspace` during loading.
    let userNamespace: MacroNamespace

    /// A mapping of GUIDs to `ProjectModelItem`s built up as the PIF is loaded.  Once all objects in the PIF have been loaded, a copy of this dictionary will be transferred to the loaded `Workspace`.
    private var knownReferences: [String: Reference] = [:]

    /// The map of loaded objects which are available, used to satisfy indirect references.
    fileprivate var loadedObjects: [PIFObjectReference: any PIFObject] = [:]

    /// Create a loader from a raw PIF object.
    ///
    /// This object is expected to be a list of top-level PIF objects.
    convenience public init(data: PropertyListItem, namespace: MacroNamespace) {
        let objects = Result<[PIFObjectReference: EncodedPIFValue], any Swift.Error> { () -> [PIFObjectReference: EncodedPIFValue] in
            var objects = [PIFObjectReference: EncodedPIFValue]()
            guard case let .plArray(pifObjects) = data else {
                throw PIFLoadingError.invalidObject(message: "top level object must be an array")
            }
            for (index, data) in pifObjects.enumerated() {
                let (pifType, signature, objectContents) = try pifObject(data: data, at: index)
                let ref = PIFObjectReference(signature: signature, type: pifType)
                if objects.contains(ref) {
                    throw PIFLoadingError.conflictingSignatures(type: pifType, signature: signature)
                }
                objects[ref] = .json(objectContents)
            }
            return objects
        }

        self.init(objects: objects, namespace: namespace)
    }

    /// Create a new loader.
    ///
    /// The set of all possible references *must* be supplied to the loader.
    ///
    /// - parameter objects: The map of referenceable objects.
    /// - parameter namespace: The namespace to use as the parent of the namespace that loading will use to parse build settings in the PIF.
    //
    // FIXME: This API is somewhat cumbersome because of how incremental loading was retrofitted in. We should clean it up.
    convenience private init(objects: Result<[PIFObjectReference: EncodedPIFValue], any Error>, namespace: MacroNamespace) {
        struct StaticObjectProvider: PIFObjectProvider {
            let objects: Result<[PIFObjectReference: EncodedPIFValue], any Error>

            func fetchObject<T: PIFObject>(signature: String, type: T.Type, loader: PIFLoader) throws -> T {
                let ref = PIFObjectReference(signature: signature, type: type.pifType)
                guard let data = try objects.get()[ref] else {
                    throw PIFLoadingError.missingObject(key: ref)
                }
                return try type.construct(from: data, signature: signature, loader: loader)
            }
        }

        // When using the convenience API, we always load into a new namespace.
        let userNamespace = MacroNamespace(parent: namespace, debugDescription: "workspace")

        self.init(provider: StaticObjectProvider(objects: objects), userNamespace: userNamespace)
    }

    /// Create a loader from a PIF object provider.
    ///
    /// This object is expected to be a list of top-level PIF objects.
    init(provider: any PIFObjectProvider, userNamespace: MacroNamespace) {
        self.userNamespace = userNamespace
        self.provider = provider
    }

    /// Load the workspace from the PIF.
    public func load(workspaceSignature: String) throws -> Workspace {
        return try MacroNamespace.withExpressionInterningEnabled {
            try loadReference(signature: workspaceSignature, type: Workspace.self)
        }
    }

    /// Load a referenced object of the given type.
    ///
    /// It is a fatal error to attempt to load a reference which is unavailable.
    //
    // FIXME: This shouldn't be fatal, the service should never die on malformed data.
    func loadReference<T: PIFObject>(signature: PIFObjectReference.Signature, type: T.Type) throws -> T {
        let key = PIFObjectReference(signature: signature, type: type.pifType)
        if let object = loadedObjects[key] {
            return object as! T
        }

        let object = try provider.fetchObject(signature: signature, type: type, loader: self)
        loadedObjects[key] = object
        return object
    }

    /// Register a ProjectModelItem by GUID so references to them elsewhere in the PIF can be resolved. It is an error to register the same GUID twice.
    ///
    /// Only items which could actually be referred to by other items need to be registered.  This isn't intended to be a generic "make sure the same GUID is never used twice in the PIF" mechanism.
    func registerReference(_ item: Reference, for guid: String) throws {
        guard knownReferences[guid] == nil else {
            throw PIFLoadingError.guidAlreadyRegistered(type: type(of: self), guid: guid)
        }
        knownReferences[guid] = item
    }

    // Return the ProjectModelItem for the requested GUID.  If one cannot be returned, that's an internal error.
    func lookupReference(for guid: String ) -> Reference? {
        return knownReferences[guid]
    }

    /// Extract the workspace signature from a raw PIF object.
    ///
    /// This object is expected to be a list of top-level PIF objects, the first of which is the workspace.
    public static func extractWorkspaceSignature(objects data: PropertyListItem) throws -> String {
        guard case .plArray(let pifObjects) = data else {
            throw PIFLoadingError.invalidObject(message: "top level object must be an array")
        }
        guard case .plDict(let workspaceObject)? = pifObjects.first else {
            throw PIFLoadingError.invalidObject(message: "first item in the top level array must be a dictionary")
        }
        guard case .plString(let type)? = workspaceObject["type"], type == "workspace" else {
            throw PIFLoadingError.invalidObject(message: "'type' property of the first item in the top level array must be 'workspace'")
        }
        guard case .plString(let signature)? = workspaceObject["signature"] else {
            throw PIFLoadingError.invalidObject(message: "missing signature in workspace object")
        }
        return signature
    }
}


/// An incremental PIF loader.
///
/// This is a PIF loader implementation which keeps track of available objects and dynamically negotiates the minimal set of objects which need to be transferred to load the complete PIF.
///
/// If enabled, this class can also manage persistent storage of PIF objects to a `FileSystem`. When this is enabled, objects which are transferred will be stored in the cache so that later transfer requests do not require the client to recompute and retransfer the PIF data.
///
/// This class is *not* thread safe.
//
// FIXME: This API doesn't feel right, it seems bogus that both the incremental loader and the regular loader are both maintaining maps of objects keyed by the same thing. The separation currently is between the incremental loader, which maintains a set of objects across multiple load requests and can communicate back to the client (via `LoadingSession`) about what new objects are required, and the bare `PIFLoader` which is only responsible for loading a single, complete graph.
public final class IncrementalPIFLoader {
    @_spi(Testing) public static let loadsRequested = Statistic("IncrementalPIFLoader.loadsRequested",
        "The total number of top-level objects requested.")
    static let objectsRequested = Statistic("IncrementalPIFLoader.objectsRequested",
        "The number of PIF objects which were requested.")
    @_spi(Testing) public static let objectsLoaded = Statistic("IncrementalPIFLoader.objectsLoaded",
        "The number of PIF objects which were loaded, in any form.")
    static let objectsCachedInMemory = Statistic("IncrementalPIFLoader.objectsCachedInMemory",
        "The number of PIF objects which hit the in-memory cache.")
    static let objectsCachedOnDisk = Statistic("IncrementalPIFLoader.objectsCachedOnDisk",
        "The number of PIF objects which hit the on-disk cache.")
    @_spi(Testing) public static let objectsTransferred = Statistic("IncrementalPIFLoader.objectsTransferred",
        "The number of PIF objects which were transferred.")

    /// A session for incrementally loading an individual object.
    ///
    /// NOTE: The loader expects that only one loading session is ever in use at a time. This is an unchecked condition.
    public final class LoadingSession {
        private struct ObjectProviderAdaptor: PIFObjectProvider {
            let session: LoadingSession

            func fetchObject<T: PIFObject>(signature: PIFObject.Signature, type: T.Type, loader: PIFLoader) throws -> T {
                let key = PIFObjectReference(signature: signature, type: type.pifType)

                // Check if we have already loaded this object.
                if let object = session.incrementalLoader.loadedObjects[key] {
                    return object as! T
                }

                // If not, load it.
                guard let data = session.availableDataObjects[key] else {
                    throw PIFLoadingError.unavailableObject(key: key)
                }

                return try type.construct(from: data, signature: signature, loader: loader)
            }
        }

        /// The incremental loader.
        let incrementalLoader: IncrementalPIFLoader

        /// The workspace signature being loaded.
        let workspaceSignature: String

        /// The available, but unloaded object data.
        var availableDataObjects: [PIFObjectReference: EncodedPIFValue] = [:]

        /// Indicates whether the PIF cache was read at least once.
        public private(set) var didUseCache = false

        /// The complete set of missing objects for the unloaded data.
        public var missingObjects: AnySequence<(signature: String, type: PIFObjectType)> {
            return AnySequence(_missingObjects.map{ (signature: $0.signature, type: $0.type) })
        }
        var _missingObjects: Set<PIFObjectReference> = []

        /// Create a workspace loading session.
        init(workspaceSignature: String, _ incrementalLoader: IncrementalPIFLoader) {
            self.workspaceSignature = workspaceSignature
            self.incrementalLoader = incrementalLoader

            let key = PIFObjectReference(signature: workspaceSignature, type: .workspace)
            addRequiredObject(key)
        }

        /// Load the named workspace.
        ///
        /// This may only be called when `missingObjects` is empty.
        public func load() throws -> Workspace {
            IncrementalPIFLoader.loadsRequested.increment()

            if !_missingObjects.isEmpty {
                throw PIFLoadingError.missingObjects(keys: _missingObjects)
            }

            // Create the loader for this instance and load the object.
            let loader = PIFLoader(provider: ObjectProviderAdaptor(session: self), userNamespace: incrementalLoader.userNamespace)
            let result = try MacroNamespace.withExpressionInterningEnabled{ try loader.loadReference(signature: workspaceSignature, type: Workspace.self) }

            // Merge back in all the loaded objects.
            for (key, value) in loader.loadedObjects {
                incrementalLoader.loadedObjects[key] = value
            }

            return result
        }

        /// Add the given raw PIF object.
        ///
        /// This will register and scan the object, and then update `missingObjects` to reflect what objects are still required, if any.
        public func add(object data: PropertyListItem) throws {
            let (pifType, signature, objectContents) = try pifObject(data: data, at: nil)

            // Validate the version compatibility. Recall that the PIF is written from Xcode, which acts at the client.
            let pifVersionForClient = try parsePIFVersion(signature)
            guard pifVersionForClient <= SWBProtocol.PIFObject.supportedPIFEncodingSchemaVersion else {
                throw PIFLoadingError.incompatiblePIFVersion(client: pifVersionForClient, service: SWBProtocol.PIFObject.supportedPIFEncodingSchemaVersion)
            }

            // Automatically decapsulate binary data.
            let value: EncodedPIFValue
            if let data = try BuildFile.parseOptionalValueForKeyAsByteString("data", pifDict: objectContents) {
                value = .binary(data)
            } else {
                value = .json(objectContents)
            }

            try add(pifType: pifType, object: value, signature: signature)
        }

        /// Add the given raw PIF object.
        ///
        /// This will register and scan the object, and then update `missingObjects` to reflect what objects are still required, if any.
        public func add(pifType: PIFObjectType, object: EncodedPIFValue, signature: String) throws {
            // It is an error to add a non-required object.
            let key = PIFObjectReference(signature: signature, type: pifType)
            if !_missingObjects.contains(key) {
                throw PIFLoadingError.nonRequiredObject(key: key)
            }

            IncrementalPIFLoader.objectsTransferred.increment()

            try add(contents: object, for: key)
        }

        /// Record a required object reference.
        func addRequiredObject(_ key: PIFObjectReference) {
            IncrementalPIFLoader.objectsRequested.increment()

            // Check if on-disk cache is still intact.
            if incrementalLoader.isOnDiskCacheIntact(for: key) {
                // If the object is available, we don't need to add it.
                if availableDataObjects.contains(key) || incrementalLoader.loadedObjects.contains(key) {
                    return IncrementalPIFLoader.objectsCachedInMemory.increment()
                }
            } else {
                // If on-disk cache was compromised, remove the in memory data for that key.
                availableDataObjects[key] = nil
                incrementalLoader.loadedObjects[key] = nil
            }

            // Check if we have an entry in the on-disk cache, and if so add it.
            if let contents = incrementalLoader.readCacheObject(for: key) {
                IncrementalPIFLoader.objectsCachedOnDisk.increment()
                self.didUseCache = true

                // If we were able to load the data, then try to add it recursively (since we will be bypassing the addition of all referenced objects).
                if let _ = try? add(contents: contents, for: key, writeToCache: false) {
                    // If we were able to add it, use the cached value.
                    return
                }

                // Otherwise, if there was an error loading the cached object then force it to be explicitly transferred (this still might fail when the actual loading is attempted).
            }

            // Otherwise, we need the client to provide the object.
            _missingObjects.insert(key)
        }

        /// Add the `contents` for the object `key`.
        ///
        /// - Parameters:
        ///   - writeToCache: If true, the object should be added to the cache if in use.
        func add(contents: EncodedPIFValue, for key: PIFObjectReference, writeToCache: Bool = true) throws {
            IncrementalPIFLoader.objectsLoaded.increment()

            // Get the list of referenced objects (which can fail), before we mutate any other data.
            let referencedObjects = try key.type.objectType.referencedObjects(for: contents)

            availableDataObjects[key] = contents

            // Record the data in the cache.
            if writeToCache {
                try incrementalLoader.writeCacheObject(contents: contents, for: key)
            }

            // Update the set of missing objects.
            _missingObjects.remove(key)
            for reference in referencedObjects {
                addRequiredObject(reference)
            }
        }
    }

    /// The user namespace to use when loading objects.
    ///
    /// This namespace is currently constant for *all* objects loaded by this interface. Eventually we would like to support actually segregating the user namespaces along workspace or project boundaries, which will require that we lift the namespace to an actual transported object we can integrate with the PIF loading process (right now, we must have a constant one so that different PIF objects always see a consistent namespace view).
    public let userNamespace: MacroNamespace

    /// The loaded objects.
    private let loadedObjects = HeavyCache<PIFObjectReference, any PIFObject>(timeToLive: Tuning.pifCacheTTL)

    @_spi(Testing) public var loadedObjectCount: Int {
        loadedObjects.count
    }

    /// The cache path, if enabled.
    var cachePath: Path?

    /// The file system to use for persistence.
    let fs: any FSProxy

    /// Create an incremental PIF loader.
    ///
    /// - Parameters:
    ///   - internalNamespace: The internal namespace, used to derive a workspace-level namespace to load all objects into.
    ///   - cachePath: If provided, the path to a directory to use for persisting PIF objects, for use in incremental restoration.
    public init(internalNamespace: MacroNamespace, cachePath: Path?, fs: any FSProxy = localFS) {
        self.userNamespace = MacroNamespace(parent: internalNamespace, debugDescription: "workspace")
        self.cachePath = cachePath
        self.fs = fs

        // FIXME: Eventually, we will want a much more sophisticated cache here,
        // with LRU eviction and versioning: <rdar://problem/28190187> Improve PIF data cache

        // If the cache is enabled, ensure the type-keyed directories exist.
        createCacheDirectories()
    }

    /// Initiate a workspace loading session.
    public func startLoading(workspaceSignature: String) -> LoadingSession {
        return LoadingSession(workspaceSignature: workspaceSignature, self)
    }

    /// Clear the persistent cache.
    public func clearCache() {
        guard cachePath != nil else { return }

        for path in cacheDirectories() {
            // FIXME: We need to handle the errors thrown from here.
            try? fs.removeDirectory(path)
        }
        // Recreate the cache directories.
        createCacheDirectories()
    }

    /// Create the persistent cache directories, if used.
    private func createCacheDirectories() {
        for path in cacheDirectories() {
            createCacheDirectory(path)
        }
    }

    /// Create directory and potentially tag it as a build directory
    private func createCacheDirectory(_ cachePath: Path) {
        // Determine the parent of "XCBuildData", because that will be the intermediates directory.
        var path = cachePath
        while path.str.contains("XCBuildData") && !path.isRoot && !path.isEmpty {
            path = path.dirname
        }

        // This is some unfortunate duplication with `CreateBuildDirectoryTaskAction`, but we have to good way to clean it up right now.
        if !fs.exists(path) {
            // FIXME: We need to handle the errors thrown from here.
            try? fs.createDirectory(path, recursive: true)
            do {
                try fs.setCreatedByBuildSystemAttribute(path)
            } catch {
                print("Couldn't set attribute on intermediates directory: \(error.localizedDescription)")
            }
        }

        // FIXME: We need to handle the errors thrown from here.
        try? fs.createDirectory(cachePath, recursive: true)
    }

    /// Returns the directories that we use for on-disk cache.
    private func cacheDirectories() -> [Path] {
        guard let cachePath else { return [] }
        return PIFObjectType.allCases.map({ cachePath.join($0.rawValue) })
    }

    /// Returns true if the on-disk cache is intact for the given key.
    ///
    /// This always returns true if on-disk cache is not active.
    private func isOnDiskCacheIntact(for key: PIFObjectReference) -> Bool {
        // Return true if we're not using on-disk cache.
        if cachePath == nil {
            return true
        }

        // Check if the on-disk cache is present.
        for isBinary in [true, false] {
            let path = cacheEntryPath(for: key, isBinary: isBinary)!
            if fs.exists(path) {
                return true
            }
        }
        return false
    }

    // MARK: Persistence

    /// Get the cache entry path for `key`.
    ///
    /// - Returns: The entry path, if the cache is in use.
    private func cacheEntryPath(for key: PIFObjectReference, isBinary: Bool) -> Path? {
        return cachePath?.join(key.type.rawValue).join(key.signature + (isBinary ? "-binary" : "-json"))
    }

    /// Cache the given object, if enabled.
    private func writeCacheObject(contents: EncodedPIFValue, for key: PIFObjectReference) throws {
        if let path = cacheEntryPath(for: key, isBinary: contents.isBinary) {
            if !fs.isDirectory(path.dirname) {
                createCacheDirectory(path.dirname)
            }
            do {
                // FIXME: Use a more efficient representation: <rdar://problem/28190187> Improve PIF data cache
                let bytes: ByteString
                switch contents {
                case .json(let contents):
                    bytes = try PropertyListItem.plDict(contents).asJSONFragment()
                case .binary(let contents):
                    bytes = contents
                }
                try fs.write(path, contents: bytes, atomically: true)
            }
        }
    }

    /// Read the cached contents for the given key, if available
    private func readCacheObject(for key: PIFObjectReference) -> EncodedPIFValue? {
        // Check if we have a binary cache entry.
        if let path = cacheEntryPath(for: key, isBinary: true), fs.exists(path) {
            // Load from the cache.
            //
            // FIXME: Use a more efficient representation: <rdar://problem/28190187> Improve PIF data cache
            if let data = try? fs.read(path) {
                return .binary(data)
            }
        }
        // Check if we have a JSON cache entry.
        if let path = cacheEntryPath(for: key, isBinary: false), fs.exists(path) {
            // Load from the cache.
            //
            // FIXME: Use a more efficient representation: <rdar://problem/28190187> Improve PIF data cache
            if let data = try? fs.read(path), let plItem = try? PropertyList.fromJSONData(data.bytes), case let .plDict(contents) = plItem {
                return .json(contents)
            }
        }
        return nil
    }
}

fileprivate func pifObject(data pifObject: PropertyListItem, at index: Int?) throws -> (pifType: PIFObjectType, signature: String, objectContents: [String: PropertyListItem]) {
    let indexInfix = index.map { index in "PIF object at index \(index) in the top level array" } ?? "PIF object"
    guard case let .plDict(contents) = pifObject else {
        throw PIFLoadingError.invalidObject(message: "\(indexInfix) must be a dictionary")
    }
    guard case let .plString(type)? = contents["type"] else {
        throw PIFLoadingError.invalidObject(message: "'type' property of \(indexInfix) is missing or is not a string")
    }
    guard case let .plString(signature)? = contents["signature"] else {
        throw PIFLoadingError.invalidObject(message: "'signature' property of '\(type)' \(indexInfix) is missing or is not a string")
    }
    guard case let .plDict(objectContents)? = contents["contents"] else {
        throw PIFLoadingError.invalidObject(message: "'contents' property of '\(type)' \(indexInfix) is missing or is not a dictionary")
    }
    guard let objectType = PIFObjectType(rawValue: type) else {
        throw PIFLoadingError.invalidObjectType(typeName: type)
    }
    return (objectType, signature, objectContents)
}
