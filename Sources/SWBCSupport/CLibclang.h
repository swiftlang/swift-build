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

// Helper interfaces for working with libclang.

#ifndef LIBCLANG_H
#define LIBCLANG_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct libclang_source_range_t_* libclang_source_range_t;
typedef struct libclang_diagnostic_set_t_* libclang_diagnostic_set_t;
typedef struct libclang_diagnostic_t_* libclang_diagnostic_t;
typedef struct libclang_diagnostic_fixit_t_* libclang_diagnostic_fixit_t;

typedef struct libclang_t_* libclang_t;
typedef struct libclang_scanner_t_* libclang_scanner_t;
typedef struct libclang_casoptions_t_* libclang_casoptions_t;
typedef struct libclang_casdatabases_t_* libclang_casdatabases_t;
typedef struct libclang_cas_casobject_t_* libclang_cas_casobject_t;
typedef struct libclang_cas_cached_compilation_t_* libclang_cas_cached_compilation_t;

typedef struct clang_version_t_ {
  int major;
  int minor;
  int patch;
  int subpatch;
  int subsubpatch;
} clang_version_t;

typedef struct {
    const char *name;
    const char *context_hash;
    const char *module_map_path;
    const char **file_deps;
    const char *include_tree_id;
    bool is_cwd_ignored;
    const char **module_deps;
    const char *cache_key;
    const char **build_arguments;
} clang_module_dependency_t;

typedef struct {
    int count;
    clang_module_dependency_t *modules;
} clang_module_dependency_set_t;

typedef struct {
    const char *context_hash;
    const char **file_deps;
    const char **module_deps;
    const char *cache_key;
    const char *executable;
    const char **build_arguments;
} clang_translation_unit_command_t;

typedef struct {
    const char *include_tree_id;
    size_t num_commands;
    clang_translation_unit_command_t *commands;
} clang_file_dependencies_t;

typedef enum {
    clang_output_kind_moduleFile = 0,
    clang_output_kind_dependencies = 1,
    clang_output_kind_dependenciesTarget = 2,
    clang_output_kind_serializedDiagnostics = 3,
} clang_output_kind_t;

/// Open an interface to libclang, from a given path.
///
/// \returns nullptr on error.
libclang_t libclang_open(const char* path);

/// Intentionally leak libclang interface.
void libclang_leak(libclang_t lib);

/// Close an open libclang interface.
void libclang_close(libclang_t lib);

/// Get the clang version string.
void libclang_get_clang_version(libclang_t lib, void (^callback)(const char*));

/// Whether the libclang has the minimal set of required API.
bool libclang_has_required_api(libclang_t lib);

/// Whether the libclang has dependency scanning support.
bool libclang_has_scanner(libclang_t lib);

/// Whether libclang supports reporting structured scanning diagnostics.
bool libclang_has_structured_scanner_diagnostics(libclang_t lib);

/// Create a new scanner instance with optional CAS databases.
libclang_scanner_t libclang_scanner_create(libclang_t lib, libclang_casdatabases_t, libclang_casoptions_t);

/// Dispose of a scanner.
void libclang_scanner_dispose(libclang_scanner_t scanner);

/// Whether the libclang has CAS support.
bool libclang_has_cas(libclang_t lib);

/// Whether the libclang has CAS plugin support.
bool libclang_has_cas_plugin_feature(libclang_t lib);

/// Whether the libclang has CAS pruning support.
bool libclang_has_cas_pruning_feature(libclang_t lib);

/// Whether the libclang has CAS up-to-date checking support.
bool libclang_has_cas_up_to_date_checks_feature(libclang_t lib);

/// Whether the libclang has current working directory optimization support.
bool libclang_has_current_working_directory_optimization(libclang_t lib);

/// Create the CAS options object.
libclang_casoptions_t libclang_casoptions_create(libclang_t lib);

/// Dispose of the CAS options object.
void libclang_casoptions_dispose(libclang_casoptions_t);

/// Set the on-disk path to be used for the CAS database instances.
void libclang_casoptions_setondiskpath(libclang_casoptions_t, const char *path);

/// Set the plugin library path to be used for the CAS database instances.
void libclang_casoptions_setpluginpath(libclang_casoptions_t, const char *path);

/// Set a value for a named option that the CAS plugin supports.
void libclang_casoptions_setpluginoption(libclang_casoptions_t, const char *name, const char *value);

/// Create the CAS database instances.
libclang_casdatabases_t libclang_casdatabases_create(libclang_casoptions_t, void (^error_callback)(const char *));

/// Dispose of the CAS databases instances.
void libclang_casdatabases_dispose(libclang_casdatabases_t);

/// Get the local storage size of the CAS/cache data in bytes.
///
/// \returns the local storage size, or -1 if the implementation does not support
/// reporting such size, or -2 if an error occurred.
int64_t libclang_casdatabases_get_ondisk_size(libclang_casdatabases_t, void (^error_callback)(const char *));

/// Set the size for limiting disk storage growth.
///
/// \param size_limit the maximum size limit in bytes. 0 means no limit. Negative values are invalid.
/// \returns true if there was an error, false otherwise.
bool libclang_casdatabases_set_ondisk_size_limit(libclang_casdatabases_t, int64_t size_limit, void (^error_callback)(const char *));

/// Prune local storage to reduce its size according to the desired size limit.
/// Pruning can happen concurrently with other operations.
///
/// \returns true if there was an error, false otherwise.
bool libclang_casdatabases_prune_ondisk_data(libclang_casdatabases_t, void (^error_callback)(const char *));

/// A callback to get the name of a given output.
///
/// \param module_name - The name of the module.
/// \param context_hash - The context hash of the module.
/// \param kind - The output kind.
/// \param output[out] - The output path or name, whose total size must be
///                    <= \p max_len.
/// \param max_len - The maximum length of \p output.
/// \returns The actual length of \p output. If the return value is > \p max_len,
///          the callback will be repeated with a larger buffer.
typedef size_t (^module_lookup_output_t)(
    const char *module_name, const char *context_hash,
    clang_output_kind_t kind, char *output, size_t max_len);

/// Scan the given Clang "cc1" invocation, looking for dependencies.
///
/// NOTE: This function is thread-safe.
///
/// \param scanner - The scanner to use.
/// \param argc - The number of arguments.
/// \param argv - The Clang cc1 command line (including a program name in
///               argv[0]).
/// \param workingDirectory - The working directory to use for evaluation.
/// \param module_lookup_output - A callback to get the name of a given module output.
/// \param modules_callback - A callback with the set of module dependencies and boolean signifying whether the list is in topological order..
/// \param callback - A block to invoke for each discovered dependency.
/// \param error_callback - A block to invoke on an error.
/// \returns True on success, false if the scanner failed.
bool libclang_scanner_scan_dependencies(
    libclang_scanner_t scanner, int argc, char *const *argv, const char *workingDirectory,
    __attribute__((noescape)) module_lookup_output_t module_lookup_output,
    __attribute__((noescape)) void (^modules_callback)(clang_module_dependency_set_t, bool),
    void (^callback)(clang_file_dependencies_t),
    void (^diagnostics_callback)(const libclang_diagnostic_set_t),
    void (^error_callback)(const char *));

/// Get the list of commands invoked by the given Clang driver command line.
///
/// \param argc - The number of arguments.
/// \param argv - The Clang cc1 command line (including a program name in
///               argv[0]).
/// \param argc - The number of environment bindings.
/// \param envp - A null terminated array of KEY=VALUE pairs (`envp`-style).
/// \returns True on success, false on failure (including if the libclang cannot
/// support).
bool libclang_driver_get_actions(libclang_t wrapped_lib,
                                 int argc,
                                 char* const* argv,
                                 char* const* envp,
                                 const char* working_directory,
                                 void (^callback)(int argc, const char** argv),
                                 void (^error_callback)(const char*));

struct libclang_diagnostic_t_ {
    char *file_name;
    unsigned int line;
    unsigned int column;
    unsigned int offset;
    int severity;
    char *text;
    char *option_name;
    char *category_text;
    unsigned int range_count;
    libclang_source_range_t *ranges;
    unsigned int fixit_count;
    libclang_diagnostic_fixit_t *fixits;
    unsigned int child_count;
    libclang_diagnostic_t *child_diagnostics;
};

struct libclang_source_range_t_ {
    char *path;
    unsigned int start_line;
    unsigned int start_column;
    unsigned int start_offset;
    unsigned int end_line;
    unsigned int end_column;
    unsigned int end_offset;
};

struct libclang_diagnostic_fixit_t_ {
    libclang_source_range_t range;
    char *text;
};

struct libclang_diagnostic_set_t_ {
    unsigned int count;
    libclang_diagnostic_t *diagnostics;
};

libclang_diagnostic_set_t libclang_read_diagnostics(libclang_t wrapped_lib,
                                                    const char* path,
                                                    const char** error_string);

void libclang_diagnostic_set_dispose(libclang_diagnostic_set_t diagnostic_set);

void libclang_cas_load_object_async(libclang_casdatabases_t, const char *casid, void (^callback)(libclang_cas_casobject_t, const char *error));
void libclang_cas_casobject_dispose(libclang_cas_casobject_t);

bool libclang_cas_casobject_is_materialized(libclang_casdatabases_t, const char *casid, void (^error_callback)(const char *));

libclang_cas_cached_compilation_t libclang_cas_get_cached_compilation(libclang_casdatabases_t, const char *cache_key, bool globally, void (^error_callback)(const char *));
void libclang_cas_get_cached_compilation_async(libclang_casdatabases_t, const char *cache_key, bool globally, void (^callback)(libclang_cas_cached_compilation_t, const char *error));

void libclang_cas_cached_compilation_dispose(libclang_cas_cached_compilation_t);

size_t libclang_cas_cached_compilation_get_num_outputs(libclang_cas_cached_compilation_t);
void libclang_cas_cached_compilation_get_output_name(libclang_cas_cached_compilation_t, size_t output_idx, void (^callback)(const char*));
void libclang_cas_cached_compilation_get_output_casid(libclang_cas_cached_compilation_t, size_t output_idx, void (^callback)(const char*));
bool libclang_cas_cached_compilation_is_output_materialized(libclang_cas_cached_compilation_t, size_t output_idx);
void libclang_cas_cached_compilation_make_global_async(libclang_cas_cached_compilation_t, void (^callback)(const char *error));

/// Synchronous call.
/// \returns True on success, false on failure.
bool libclang_cas_replay_compilation(libclang_cas_cached_compilation_t, int argc, char *const *argv, const char *workingDirectory, void (^callback)(const char* diagnostic_text, const char *error));

#ifdef __cplusplus
}
#endif

#endif /* LIBCLANG_H */
