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

#include "PluginAPI_functions.h"
#include "PluginAPI_types.h"

#ifndef PLUGINAPI_H
#define PLUGINAPI_H

typedef struct {
    typeof(&llcas_get_plugin_version) _Nonnull llcas_get_plugin_version;
    typeof(&llcas_string_dispose) _Nonnull llcas_string_dispose;
    typeof(&llcas_cancellable_cancel) _Nullable llcas_cancellable_cancel;
    typeof(&llcas_cancellable_dispose) _Nullable llcas_cancellable_dispose;
    typeof(&llcas_cas_options_create) _Nonnull llcas_cas_options_create;
    typeof(&llcas_cas_options_dispose) _Nonnull llcas_cas_options_dispose;
    typeof(&llcas_cas_options_set_client_version) _Nonnull llcas_cas_options_set_client_version;
    typeof(&llcas_cas_options_set_ondisk_path) _Nonnull llcas_cas_options_set_ondisk_path;
    typeof(&llcas_cas_options_set_option) _Nonnull llcas_cas_options_set_option;
    typeof(&llcas_cas_create) _Nonnull llcas_cas_create;
    typeof(&llcas_cas_dispose) _Nonnull llcas_cas_dispose;
    typeof(&llcas_cas_get_ondisk_size) _Nullable llcas_cas_get_ondisk_size;
    typeof(&llcas_cas_set_ondisk_size_limit) _Nullable llcas_cas_set_ondisk_size_limit;
    typeof(&llcas_cas_prune_ondisk_data) _Nullable llcas_cas_prune_ondisk_data;
    typeof(&llcas_cas_get_hash_schema_name) _Nonnull llcas_cas_get_hash_schema_name;
    typeof(&llcas_digest_parse) _Nonnull llcas_digest_parse;
    typeof(&llcas_digest_print) _Nonnull llcas_digest_print;
    typeof(&llcas_cas_get_objectid) _Nonnull llcas_cas_get_objectid;
    typeof(&llcas_objectid_get_digest) _Nonnull llcas_objectid_get_digest;
    typeof(&llcas_cas_contains_object) _Nonnull llcas_cas_contains_object;
    typeof(&llcas_cas_load_object) _Nonnull llcas_cas_load_object;
    typeof(&llcas_cas_load_object_async) _Nonnull llcas_cas_load_object_async;
    typeof(&llcas_cas_store_object) _Nonnull llcas_cas_store_object;
    typeof(&llcas_loaded_object_get_data) _Nonnull llcas_loaded_object_get_data;
    typeof(&llcas_loaded_object_get_refs) _Nonnull llcas_loaded_object_get_refs;
    typeof(&llcas_object_refs_get_count) _Nonnull llcas_object_refs_get_count;
    typeof(&llcas_object_refs_get_id) _Nonnull llcas_object_refs_get_id;
    typeof(&llcas_actioncache_get_for_digest) _Nonnull llcas_actioncache_get_for_digest;
    typeof(&llcas_actioncache_get_for_digest_async) _Nonnull llcas_actioncache_get_for_digest_async;
    typeof(&llcas_actioncache_put_for_digest) _Nonnull llcas_actioncache_put_for_digest;
    typeof(&llcas_actioncache_put_for_digest_async) _Nonnull llcas_actioncache_put_for_digest_async;
} plugin_api_t;


#endif /* PLUGINAPI_H */
