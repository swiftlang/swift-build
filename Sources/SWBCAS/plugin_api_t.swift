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
import SWBUtil

extension plugin_api_t {
    init(_ handle: LibraryHandle) throws {
        func loadRequired<T>(_ symbol: String) throws -> T {
            guard let sym: T = Library.lookup(handle, symbol) else {
                throw ToolchainCASPluginError.missingRequiredSymbol(symbol)
          }
          return sym
        }
        func loadOptional<T>(_ symbol: String) -> T? {
            guard let sym: T = Library.lookup(handle, symbol) else {
                return nil
          }
          return sym
        }
        self.init(llcas_get_plugin_version: try loadRequired("llcas_get_plugin_version"),
                  llcas_string_dispose: try loadRequired("llcas_string_dispose"),
                  llcas_cancellable_cancel: loadOptional("llcas_cancellable_cancel"),
                  llcas_cancellable_dispose: loadOptional("llcas_cancellable_dispose"),
                  llcas_cas_options_create: try loadRequired("llcas_cas_options_create"),
                  llcas_cas_options_dispose: try loadRequired("llcas_cas_options_dispose"),
                  llcas_cas_options_set_client_version: try loadRequired("llcas_cas_options_set_client_version"),
                  llcas_cas_options_set_ondisk_path: try loadRequired("llcas_cas_options_set_ondisk_path"),
                  llcas_cas_options_set_option: try loadRequired("llcas_cas_options_set_option"),
                  llcas_cas_create: try loadRequired("llcas_cas_create"),
                  llcas_cas_dispose: try loadRequired("llcas_cas_dispose"),
                  llcas_cas_get_ondisk_size: loadOptional("llcas_cas_get_ondisk_size"),
                  llcas_cas_set_ondisk_size_limit: loadOptional("llcas_cas_set_ondisk_size_limit"),
                  llcas_cas_prune_ondisk_data: loadOptional("llcas_cas_prune_ondisk_data"),
                  llcas_cas_get_hash_schema_name: try loadRequired("llcas_cas_get_hash_schema_name"),
                  llcas_digest_parse: try loadRequired("llcas_digest_parse"),
                  llcas_digest_print: try loadRequired("llcas_digest_print"),
                  llcas_cas_get_objectid: try loadRequired("llcas_cas_get_objectid"),
                  llcas_objectid_get_digest: try loadRequired("llcas_objectid_get_digest"),
                  llcas_cas_contains_object: try loadRequired("llcas_cas_contains_object"),
                  llcas_cas_load_object: try loadRequired("llcas_cas_load_object"),
                  llcas_cas_load_object_async: try loadRequired("llcas_cas_load_object_async"),
                  llcas_cas_store_object: try loadRequired("llcas_cas_store_object"),
                  llcas_loaded_object_get_data: try loadRequired("llcas_loaded_object_get_data"),
                  llcas_loaded_object_get_refs: try loadRequired("llcas_loaded_object_get_refs"),
                  llcas_object_refs_get_count: try loadRequired("llcas_object_refs_get_count"),
                  llcas_object_refs_get_id: try loadRequired("llcas_object_refs_get_id"),
                  llcas_actioncache_get_for_digest: try loadRequired("llcas_actioncache_get_for_digest"),
                  llcas_actioncache_get_for_digest_async: try loadRequired("llcas_actioncache_get_for_digest_async"),
                  llcas_actioncache_put_for_digest: try loadRequired("llcas_actioncache_put_for_digest"),
                  llcas_actioncache_put_for_digest_async: try loadRequired("llcas_actioncache_put_for_digest_async"))
    }
}
