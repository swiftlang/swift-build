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

import SWBCSupport
import Foundation

public final class IndexStore {

    public struct TestCaseClass {
        public struct TestMethod: Hashable, Comparable {
            public let name: String
            public let isAsync: Bool

            public static func < (lhs: IndexStore.TestCaseClass.TestMethod, rhs: IndexStore.TestCaseClass.TestMethod) -> Bool {
                return (lhs.name, (lhs.isAsync ? 1 : 0)) < (rhs.name, (rhs.isAsync ? 1 : 0))
            }
        }

        public var name: String
        public var module: String
        public var testMethods: [TestMethod]
        @available(*, deprecated, message: "use testMethods instead") public var methods: [String]
    }

    fileprivate var impl: IndexStoreImpl { _impl as! IndexStoreImpl }
    private let _impl: Any

    fileprivate init(_ impl: IndexStoreImpl) {
        self._impl = impl
    }

    static public func open(store path: Path, api: IndexStoreAPI) throws -> IndexStore {
        let impl = try IndexStoreImpl.open(store: path, api: api.impl)
        return IndexStore(impl)
    }

    public func listTests(in objectFiles: [Path]) throws -> [TestCaseClass] {
        return try impl.listTests(in: objectFiles)
    }

    @available(*, deprecated, message: "use listTests(in:) instead")
    public func listTests(inObjectFile object: Path) throws -> [TestCaseClass] {
        return try impl.listTests(inObjectFile: object)
    }
}

public final class IndexStoreAPI {
    fileprivate var impl: IndexStoreAPIImpl {
        _impl as! IndexStoreAPIImpl
    }
    private let _impl: Any

    public init(dylib path: Path) throws {
        self._impl = try IndexStoreAPIImpl(dylib: path)
    }
}

private final class IndexStoreImpl {
    typealias TestCaseClass = IndexStore.TestCaseClass

    let api: IndexStoreAPIImpl

    let store: indexstore_t

    private init(store: indexstore_t, api: IndexStoreAPIImpl) {
        self.store = store
        self.api = api
    }

    static public func open(store path: Path, api: IndexStoreAPIImpl) throws -> IndexStoreImpl {
        if let store = try api.call({ api.fn.store_create(path.str, &$0) }) {
            return IndexStoreImpl(store: store, api: api)
        }
        throw StubError.error("Unable to open store at \(path.str)")
    }

    public func listTests(in objectFiles: [Path]) throws -> [TestCaseClass] {
        var inheritance = [String: [String: String]]()
        var testMethods = [String: [String: [(name: String, async: Bool)]]]()

        for objectFile in objectFiles {
            // Get the records of this object file.
            guard let unitReader = try? self.api.call ({ self.api.fn.unit_reader_create(store, unitName(object: objectFile), &$0) }) else {
                continue
            }
            let records = try getRecords(unitReader: unitReader)
            let moduleName = self.api.fn.unit_reader_get_module_name(unitReader).str
            for record in records {
                // get tests info
                let testsInfo = try self.getTestsInfo(record: record)
                // merge results across module
                for (className, parentClassName) in testsInfo.inheritance {
                    inheritance[moduleName, default: [:]][className] = parentClassName
                }
                for (className, classTestMethods) in testsInfo.testMethods {
                    testMethods[moduleName, default: [:]][className, default: []].append(contentsOf: classTestMethods)
                }
            }
        }

        // merge across inheritance in module boundries
        func flatten(moduleName: String, className: String) -> [String: (name: String, async: Bool)] {
            var allMethods = [String: (name: String, async: Bool)]()

            if let parentClassName = inheritance[moduleName]?[className] {
                let parentMethods = flatten(moduleName: moduleName, className: parentClassName)
                allMethods.merge(parentMethods, uniquingKeysWith:  { (lhs, _) in lhs })
            }

            for method in testMethods[moduleName]?[className] ?? [] {
                allMethods[method.name] = (name: method.name, async: method.async)
            }

            return allMethods
        }

        var testCaseClasses = [TestCaseClass]()
        for (moduleName, classMethods) in testMethods {
            for className in classMethods.keys {
                let methods = flatten(moduleName: moduleName, className: className)
                    .map { (name, info) in TestCaseClass.TestMethod(name: name, isAsync: info.async) }
                    .sorted()
                testCaseClasses.append(TestCaseClass(name: className, module: moduleName, testMethods: methods, methods: methods.map(\.name)))
            }
        }

        return testCaseClasses
    }


    @available(*, deprecated, message: "use listTests(in:) instead")
    public func listTests(inObjectFile object: Path) throws -> [TestCaseClass] {
        // Get the records of this object file.
        let unitReader = try api.call{ self.api.fn.unit_reader_create(store, unitName(object: object), &$0) }
        let records = try getRecords(unitReader: unitReader)

        // Get the test classes.
        var inheritance = [String: String]()
        var testMethods = [String: [(name: String, async: Bool)]]()

        for record in records {
            let testsInfo = try self.getTestsInfo(record: record)
            inheritance.merge(testsInfo.inheritance, uniquingKeysWith: { (lhs, _) in lhs })
            testMethods.merge(testsInfo.testMethods, uniquingKeysWith: { (lhs, _) in lhs })
        }

        func flatten(className: String) -> [(method: String, async: Bool)] {
            var results = [(String, Bool)]()
            if let parentClassName = inheritance[className] {
                let parentMethods = flatten(className: parentClassName)
                results.append(contentsOf: parentMethods)
            }
            if let methods = testMethods[className] {
                results.append(contentsOf: methods)
            }
            return results
        }

        let moduleName = self.api.fn.unit_reader_get_module_name(unitReader).str

        var testCaseClasses = [TestCaseClass]()
        for className in testMethods.keys {
            let methods = flatten(className: className)
                .map { TestCaseClass.TestMethod(name: $0.method, isAsync: $0.async) }
                .sorted()
            testCaseClasses.append(TestCaseClass(name: className, module: moduleName, testMethods: methods, methods: methods.map(\.name)))
        }

        return testCaseClasses
    }

    private func getTestsInfo(record: String) throws -> (inheritance: [String: String], testMethods: [String: [(name: String, async: Bool)]] ) {
        let recordReader = try api.call{ self.api.fn.record_reader_create(store, record, &$0) }

        // scan for inheritance

        let inheritanceStoreRef = StoreRef([String: String](), api: self.api)
        let inheritancePointer = unsafeBitCast(Unmanaged.passUnretained(inheritanceStoreRef), to: UnsafeMutableRawPointer.self)

        _ = self.api.fn.record_reader_occurrences_apply_f(recordReader, inheritancePointer) { inheritancePointer , occ -> Bool in
            let inheritanceStoreRef = Unmanaged<StoreRef<[String: String?]>>.fromOpaque(inheritancePointer!).takeUnretainedValue()
            let fn = inheritanceStoreRef.api.fn

            // Get the symbol.
            let sym = fn.occurrence_get_symbol(occ)
            let symbolProperties = fn.symbol_get_properties(sym)
            // We only care about symbols that are marked unit tests and are instance methods.
            if symbolProperties & UInt64(INDEXSTORE_SYMBOL_PROPERTY_UNITTEST.rawValue) == 0 {
                return true
            }
            if fn.symbol_get_kind(sym) != INDEXSTORE_SYMBOL_KIND_CLASS{
                return true
            }

            let parentClassName = fn.symbol_get_name(sym).str

            let childClassNameStoreRef = StoreRef("", api: inheritanceStoreRef.api)
            let childClassNamePointer = unsafeBitCast(Unmanaged.passUnretained(childClassNameStoreRef), to: UnsafeMutableRawPointer.self)
            _ = fn.occurrence_relations_apply_f(occ!, childClassNamePointer) { childClassNamePointer, relation in
                guard let relation = relation else { return true }
                let childClassNameStoreRef = Unmanaged<StoreRef<String>>.fromOpaque(childClassNamePointer!).takeUnretainedValue()
                let fn = childClassNameStoreRef.api.fn

                // Look for the base class.
                if fn.symbol_relation_get_roles(relation) != UInt64(INDEXSTORE_SYMBOL_ROLE_REL_BASEOF.rawValue) {
                    return true
                }

                let childClassNameSym = fn.symbol_relation_get_symbol(relation)
                childClassNameStoreRef.instance = fn.symbol_get_name(childClassNameSym).str
                return true
            }

            if !childClassNameStoreRef.instance.isEmpty {
                inheritanceStoreRef.instance[childClassNameStoreRef.instance] = parentClassName
            }

            return true
        }

        // scan for methods

        let testMethodsStoreRef = StoreRef([String: [(name: String, async: Bool)]](), api: api)
        let testMethodsPointer = unsafeBitCast(Unmanaged.passUnretained(testMethodsStoreRef), to: UnsafeMutableRawPointer.self)

        _ = self.api.fn.record_reader_occurrences_apply_f(recordReader, testMethodsPointer) { testMethodsPointer , occ -> Bool in
            let testMethodsStoreRef = Unmanaged<StoreRef<[String: [(name: String, async: Bool)]]>>.fromOpaque(testMethodsPointer!).takeUnretainedValue()
            let fn = testMethodsStoreRef.api.fn

            // Get the symbol.
            let sym = fn.occurrence_get_symbol(occ)
            let symbolProperties = fn.symbol_get_properties(sym)
            // We only care about symbols that are marked unit tests and are instance methods.
            if symbolProperties & UInt64(INDEXSTORE_SYMBOL_PROPERTY_UNITTEST.rawValue) == 0 {
                return true
            }
            if fn.symbol_get_kind(sym) != INDEXSTORE_SYMBOL_KIND_INSTANCEMETHOD {
                return true
            }

            let classNameStoreRef = StoreRef("", api: testMethodsStoreRef.api)
            let classNamePointer = unsafeBitCast(Unmanaged.passUnretained(classNameStoreRef), to: UnsafeMutableRawPointer.self)

            _ = fn.occurrence_relations_apply_f(occ!, classNamePointer) { classNamePointer, relation in
                guard let relation = relation else { return true }
                let classNameStoreRef = Unmanaged<StoreRef<String>>.fromOpaque(classNamePointer!).takeUnretainedValue()
                let fn = classNameStoreRef.api.fn

                // Look for the class.
                if fn.symbol_relation_get_roles(relation) != UInt64(INDEXSTORE_SYMBOL_ROLE_REL_CHILDOF.rawValue) {
                    return true
                }

                let classNameSym = fn.symbol_relation_get_symbol(relation)
                classNameStoreRef.instance = fn.symbol_get_name(classNameSym).str
                return true
            }

            if !classNameStoreRef.instance.isEmpty {
                let methodName = fn.symbol_get_name(sym).str
                let isAsync = symbolProperties & UInt64(INDEXSTORE_SYMBOL_PROPERTY_SWIFT_ASYNC.rawValue) != 0
                testMethodsStoreRef.instance[classNameStoreRef.instance, default: []].append((name: methodName, async: isAsync))
            }

            return true
        }

        return (
            inheritance: inheritanceStoreRef.instance,
            testMethods: testMethodsStoreRef.instance
        )

    }

    private func getRecords(unitReader: indexstore_unit_reader_t?) throws -> [String] {
        let builder = StoreRef([String](), api: api)

        let ctx = unsafeBitCast(Unmanaged.passUnretained(builder), to: UnsafeMutableRawPointer.self)
        _ = self.api.fn.unit_reader_dependencies_apply_f(unitReader, ctx) { ctx , unit -> Bool in
            let store = Unmanaged<StoreRef<[String]>>.fromOpaque(ctx!).takeUnretainedValue()
            let fn = store.api.fn
            if fn.unit_dependency_get_kind(unit) == INDEXSTORE_UNIT_DEPENDENCY_RECORD {
                store.instance.append(fn.unit_dependency_get_name(unit).str)
            }
            return true
        }

        return builder.instance
    }

    private func unitName(object: Path) -> String {
        let initialSize = 64
        var buf = UnsafeMutablePointer<CChar>.allocate(capacity: initialSize)
        let len = self.api.fn.store_get_unit_name_from_output_path(store, object.str, buf, initialSize)

        if len + 1 > initialSize {
            buf.deallocate()
            buf = UnsafeMutablePointer<CChar>.allocate(capacity: len + 1)
            _ = self.api.fn.store_get_unit_name_from_output_path(store, object.str, buf, len + 1)
        }

        defer {
            buf.deallocate()
        }

        return String(cString: buf)
    }
}

private class StoreRef<T> {
    let api: IndexStoreAPIImpl
    var instance: T
    init(_ instance: T, api: IndexStoreAPIImpl) {
        self.instance = instance
        self.api = api
    }
}

private final class IndexStoreAPIImpl {

    /// The path of the index store dylib.
    private let path: Path

    /// Handle of the dynamic library.
    private let dylib: LibraryHandle

    /// The index store API functions.
    fileprivate let fn: indexstore_functions_t

    fileprivate func call<T>(_ fn: (inout indexstore_error_t?) -> T) throws -> T {
        var error: indexstore_error_t? = nil
        let ret = fn(&error)

        if let error = error {
            if let desc = self.fn.error_get_description(error) {
                throw StubError.error(String(cString: desc))
            }
            throw StubError.error("Unable to get description for error: \(error)")
        }

        return ret
    }

    public init(dylib path: Path) throws {
        self.path = path
        self.dylib = try Library.open(path)

        var api = indexstore_functions_t()
        api.store_create = Library.lookup(dylib, "indexstore_store_create")
        api.store_get_unit_name_from_output_path = Library.lookup(dylib,  "indexstore_store_get_unit_name_from_output_path")
        api.unit_reader_create = Library.lookup(dylib,  "indexstore_unit_reader_create")
        api.error_get_description = Library.lookup(dylib,  "indexstore_error_get_description")
        api.unit_reader_dependencies_apply_f = Library.lookup(dylib,  "indexstore_unit_reader_dependencies_apply_f")
        api.unit_reader_get_module_name = Library.lookup(dylib,  "indexstore_unit_reader_get_module_name")
        api.unit_dependency_get_kind = Library.lookup(dylib,  "indexstore_unit_dependency_get_kind")
        api.unit_dependency_get_name = Library.lookup(dylib,  "indexstore_unit_dependency_get_name")
        api.record_reader_create = Library.lookup(dylib,  "indexstore_record_reader_create")
        api.symbol_get_name = Library.lookup(dylib,  "indexstore_symbol_get_name")
        api.symbol_get_properties = Library.lookup(dylib,  "indexstore_symbol_get_properties")
        api.symbol_get_kind = Library.lookup(dylib,  "indexstore_symbol_get_kind")
        api.record_reader_occurrences_apply_f = Library.lookup(dylib,  "indexstore_record_reader_occurrences_apply_f")
        api.occurrence_get_symbol = Library.lookup(dylib,  "indexstore_occurrence_get_symbol")
        api.occurrence_relations_apply_f = Library.lookup(dylib,  "indexstore_occurrence_relations_apply_f")
        api.symbol_relation_get_symbol = Library.lookup(dylib,  "indexstore_symbol_relation_get_symbol")
        api.symbol_relation_get_roles = Library.lookup(dylib,  "indexstore_symbol_relation_get_roles")

        self.fn = api
    }
}

extension indexstore_string_ref_t {
    fileprivate var str: String {
        return String(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: data),
            length: length,
            encoding: .utf8,
            freeWhenDone: false
        )!
    }
}
