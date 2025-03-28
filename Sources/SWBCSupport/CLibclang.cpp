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

#include "CLibclang.h"

// FIXME: Horrible workaround for ::gets not being found by cstdio, on Ubuntu
// 14.04 in C++14 mode.
#if defined(__linux) && (defined __cplusplus && __cplusplus > 201103L)
extern "C" {
    extern char *gets (char *__s);
}
#endif

#include <cassert>
#include <cstring>
#include <codecvt>
#include <list>
#include <locale>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <libloaderapi.h>
#else
#include <dlfcn.h>
#endif

#ifdef _WIN32
#define LOOKUP_HANDLE_TYPE HMODULE
#define LOOKUP_FN GetProcAddress
#define DLLIMPORT __declspec(dllimport)
#else
#define LOOKUP_HANDLE_TYPE void*
#define LOOKUP_FN dlsym
#define DLLIMPORT
#endif

#ifdef __APPLE__
#include <Block.h>
#else
// Block.h is not available in the default search path for package builds, copy the two declarations we need locally for now.
DLLIMPORT extern "C" void *_Block_copy(const void *);
DLLIMPORT extern "C" void _Block_release(const void *);
#define Block_copy(...) ((__typeof(__VA_ARGS__))_Block_copy((const void *)(__VA_ARGS__)))
#define Block_release(...) _Block_release((const void *)(__VA_ARGS__))
#endif

extern "C" {
    struct LibclangFunctions {
        /**
         * Error codes returned by libclang routines.
         *
         * Zero (\c CXError_Success) is the only error code indicating success.  Other
         * error codes, including not yet assigned non-zero values, indicate errors.
         */
        enum CXErrorCode {
          /**
           * No error.
           */
          CXError_Success = 0,

          /**
           * A generic error code, no further details are available.
           *
           * Errors of this kind can get their own specific error codes in future
           * libclang versions.
           */
          CXError_Failure = 1,

          /**
           * libclang crashed while performing the requested operation.
           */
          CXError_Crashed = 2,

          /**
           * The function detected that the arguments violate the function
           * contract.
           */
          CXError_InvalidArguments = 3,

          /**
           * An AST deserialization error has occurred.
           */
          CXError_ASTReadError = 4,

          /**
          * \brief A refactoring action is not available at the given location
          * or in the given source range.
          */
          CXError_RefactoringActionUnavailable = 5,

          /**
          * \brief A refactoring action is not able to use the given name because
          * it contains an unexpected number of strings.
          */
          CXError_RefactoringNameSizeMismatch = 6,

          /**
          * \brief A name of a symbol is invalid, i.e. it is reserved by the source
          * language and can't be used as a name for this symbol.
          */
          CXError_RefactoringNameInvalid = 7
        };

        /**
         * Represents an error with error code and description string.
         */
        typedef struct CXOpaqueError *CXError;

        /**
         * \returns the error code.
         */
        enum CXErrorCode (*clang_Error_getCode)(CXError);

        /**
         * \returns the error description string.
         */
        const char *(*clang_Error_getDescription)(CXError);

        /**
         * Dispose of a \c CXError object.
         */
        void (*clang_Error_dispose)(CXError);

        /**
         * A character string.
         *
         * The \c CXString type is used to return strings from the interface when
         * the ownership of that string might differ from one call to the next.
         * Use \c clang_getCString() to retrieve the string data and, once finished
         * with the string data, call \c clang_disposeString() to free the string.
         */
        typedef struct {
            const void *data;
            unsigned private_flags;
        } CXString;

        typedef struct {
            CXString *Strings;
            unsigned Count;
        } CXStringSet;

        /**
         * An array of C strings.
         */
        typedef struct {
          const char **Strings;
          size_t Count;
        } CXCStringArray;

        /**
         * Retrieve the character data associated with the given string.
         */
        const char *(*clang_getCString)(CXString string);

        /**
         * Free the given string.
         */
        void (*clang_disposeString)(CXString string);

        /**
         * Free the given string set.
         */
        void (*clang_disposeStringSet)(CXStringSet *set);

        /**
         * Return a version string, suitable for showing to a user, but not
         * intended to be parsed (the format is not guaranteed to be stable).
         */
        CXString (*clang_getClangVersion)();

        // MARK: Diagnostics

        /**
         * A particular source file that is part of a translation unit.
         */
        typedef void *CXFile;

        /**
         * Retrieve the complete file and path name of the given file.
         */
        CXString (*clang_getFileName)(CXFile SFile);

        /**
         * Identifies a specific source location within a translation
         * unit.
         *
         * Use clang_getExpansionLocation() or clang_getSpellingLocation()
         * to map a source location to a particular file, line, and column.
         */
        typedef struct {
          const void *ptr_data[2];
          unsigned int_data;
        } CXSourceLocation;

        /**
         * Identifies a half-open character range in the source code.
         *
         * Use clang_getRangeStart() and clang_getRangeEnd() to retrieve the
         * starting and end locations from a source range, respectively.
         */
        typedef struct {
          const void *ptr_data[2];
          unsigned begin_int_data;
          unsigned end_int_data;
        } CXSourceRange;

        /**
         * Retrieve the file, line, column, and offset represented by
         * the given source location.
         *
         * If the location refers into a macro instantiation, return where the
         * location was originally spelled in the source file.
         *
         * \param location the location within a source file that will be decomposed
         * into its parts.
         *
         * \param file [out] if non-NULL, will be set to the file to which the given
         * source location points.
         *
         * \param line [out] if non-NULL, will be set to the line to which the given
         * source location points.
         *
         * \param column [out] if non-NULL, will be set to the column to which the given
         * source location points.
         *
         * \param offset [out] if non-NULL, will be set to the offset into the
         * buffer to which the given source location points.
         */
        void (*clang_getSpellingLocation)(CXSourceLocation location,
                                          CXFile *file,
                                          unsigned *line,
                                          unsigned *column,
                                          unsigned *offset);

        /**
         * Retrieve a source location representing the first character within a
         * source range.
         */
        CXSourceLocation (*clang_getRangeStart)(CXSourceRange range);

        /**
         * Retrieve a source location representing the last character within a
         * source range.
         */
        CXSourceLocation (*clang_getRangeEnd)(CXSourceRange range);

        /**
         * Describes the severity of a particular diagnostic.
         */
        enum CXDiagnosticSeverity {
          /**
           * A diagnostic that has been suppressed, e.g., by a command-line
           * option.
           */
          CXDiagnostic_Ignored = 0,

          /**
           * This diagnostic is a note that should be attached to the
           * previous (non-note) diagnostic.
           */
          CXDiagnostic_Note    = 1,

          /**
           * This diagnostic indicates suspicious code that may not be
           * wrong.
           */
          CXDiagnostic_Warning = 2,

          /**
           * This diagnostic indicates that the code is ill-formed.
           */
          CXDiagnostic_Error   = 3,

          /**
           * This diagnostic indicates that the code is ill-formed such
           * that future parser recovery is unlikely to produce useful
           * results.
           */
          CXDiagnostic_Fatal   = 4
        };

        /**
         * A single diagnostic, containing the diagnostic's severity,
         * location, text, source ranges, and fix-it hints.
         */
        typedef void *CXDiagnostic;

        /**
         * A group of CXDiagnostics.
         */
        typedef void *CXDiagnosticSet;

        /**
         * Determine the number of diagnostics in a CXDiagnosticSet.
         */
        unsigned (*clang_getNumDiagnosticsInSet)(CXDiagnosticSet Diags);

        /**
         * Retrieve a diagnostic associated with the given CXDiagnosticSet.
         *
         * \param Diags the CXDiagnosticSet to query.
         * \param Index the zero-based diagnostic number to retrieve.
         *
         * \returns the requested diagnostic. This diagnostic must be freed
         * via a call to \c clang_disposeDiagnostic().
         */
        CXDiagnostic (*clang_getDiagnosticInSet)(CXDiagnosticSet Diags,
                                                 unsigned Index);

        /**
         * Describes the kind of error that occurred (if any) in a call to
         * \c clang_loadDiagnostics.
         */
        enum CXLoadDiag_Error {
          /**
           * Indicates that no error occurred.
           */
          CXLoadDiag_None = 0,

          /**
           * Indicates that an unknown error occurred while attempting to
           * deserialize diagnostics.
           */
          CXLoadDiag_Unknown = 1,

          /**
           * Indicates that the file containing the serialized diagnostics
           * could not be opened.
           */
          CXLoadDiag_CannotLoad = 2,

          /**
           * Indicates that the serialized diagnostics file is invalid or
           * corrupt.
           */
          CXLoadDiag_InvalidFile = 3
        };

        /**
         * Deserialize a set of diagnostics from a Clang diagnostics bitcode
         * file.
         *
         * \param file The name of the file to deserialize.
         * \param error A pointer to a enum value recording if there was a problem
         *        deserializing the diagnostics.
         * \param errorString A pointer to a CXString for recording the error string
         *        if the file was not successfully loaded.
         *
         * \returns A loaded CXDiagnosticSet if successful, and NULL otherwise.  These
         * diagnostics should be released using clang_disposeDiagnosticSet().
         */
        CXDiagnosticSet (*clang_loadDiagnostics)(const char *file,
                                                 CXLoadDiag_Error *error,
                                                 CXString *errorString);

        /**
         * Release a CXDiagnosticSet and all of its contained diagnostics.
         */
        void (*clang_disposeDiagnosticSet)(CXDiagnosticSet Diags);

        /**
         * Retrieve the child diagnostics of a CXDiagnostic.
         *
         * This CXDiagnosticSet does not need to be released by
         * clang_disposeDiagnosticSet.
         */
        CXDiagnosticSet (*clang_getChildDiagnostics)(CXDiagnostic D);

        /**
         * Destroy a diagnostic.
         */
        void (*clang_disposeDiagnostic)(CXDiagnostic Diagnostic);

        /**
         * Format the given diagnostic in a manner that is suitable for display.
         *
         * This routine will format the given diagnostic to a string, rendering
         * the diagnostic according to the various options given. The
         * \c clang_defaultDiagnosticDisplayOptions() function returns the set of
         * options that most closely mimics the behavior of the clang compiler.
         *
         * \param Diagnostic The diagnostic to print.
         *
         * \param Options A set of options that control the diagnostic display,
         * created by combining \c CXDiagnosticDisplayOptions values.
         *
         * \returns A new string containing for formatted diagnostic.
         */
        CXString (*clang_formatDiagnostic)(CXDiagnostic Diagnostic,
                                           unsigned Options);

        /**
         * Retrieve the set of display options most similar to the
         * default behavior of the clang compiler.
         *
         * \returns A set of display options suitable for use with \c
         * clang_formatDiagnostic().
         */
        unsigned (*clang_defaultDiagnosticDisplayOptions)(void);

        /**
         * Determine the severity of the given diagnostic.
         */
        enum CXDiagnosticSeverity (*clang_getDiagnosticSeverity)(CXDiagnostic);

        /**
         * Retrieve the source location of the given diagnostic.
         *
         * This location is where Clang would print the caret ('^') when
         * displaying the diagnostic on the command line.
         */
        CXSourceLocation (*clang_getDiagnosticLocation)(CXDiagnostic);

        /**
         * Retrieve the text of the given diagnostic.
         */
        CXString (*clang_getDiagnosticSpelling)(CXDiagnostic);

        /**
         * Retrieve the name of the command-line option that enabled this
         * diagnostic.
         *
         * \param Diag The diagnostic to be queried.
         *
         * \param Disable If non-NULL, will be set to the option that disables this
         * diagnostic (if any).
         *
         * \returns A string that contains the command-line option used to enable this
         * warning, such as "-Wconversion" or "-pedantic".
         */
        CXString (*clang_getDiagnosticOption)(CXDiagnostic Diag,
                                              CXString *Disable);

        /**
         * Retrieve the category number for this diagnostic.
         *
         * Diagnostics can be categorized into groups along with other, related
         * diagnostics (e.g., diagnostics under the same warning flag). This routine
         * retrieves the category number for the given diagnostic.
         *
         * \returns The number of the category that contains this diagnostic, or zero
         * if this diagnostic is uncategorized.
         */
        unsigned (*clang_getDiagnosticCategory)(CXDiagnostic);

        /**
         * Retrieve the diagnostic category text for a given diagnostic.
         *
         * \returns The text of the given diagnostic category.
         */
        CXString (*clang_getDiagnosticCategoryText)(CXDiagnostic);

        /**
         * Determine the number of source ranges associated with the given
         * diagnostic.
         */
        unsigned (*clang_getDiagnosticNumRanges)(CXDiagnostic);

        /**
         * Retrieve a source range associated with the diagnostic.
         *
         * A diagnostic's source ranges highlight important elements in the source
         * code. On the command line, Clang displays source ranges by
         * underlining them with '~' characters.
         *
         * \param Diagnostic the diagnostic whose range is being extracted.
         *
         * \param Range the zero-based index specifying which range to
         *
         * \returns the requested source range.
         */
        CXSourceRange (*clang_getDiagnosticRange)(CXDiagnostic Diagnostic,
                                                  unsigned Range);

        /**
         * Determine the number of fix-it hints associated with the
         * given diagnostic.
         */
        unsigned (*clang_getDiagnosticNumFixIts)(CXDiagnostic Diagnostic);

        /**
         * Retrieve the replacement information for a given fix-it.
         *
         * Fix-its are described in terms of a source range whose contents
         * should be replaced by a string. This approach generalizes over
         * three kinds of operations: removal of source code (the range covers
         * the code to be removed and the replacement string is empty),
         * replacement of source code (the range covers the code to be
         * replaced and the replacement string provides the new code), and
         * insertion (both the start and end of the range point at the
         * insertion location, and the replacement string provides the text to
         * insert).
         *
         * \param Diagnostic The diagnostic whose fix-its are being queried.
         *
         * \param FixIt The zero-based index of the fix-it.
         *
         * \param ReplacementRange The source range whose contents will be
         * replaced with the returned replacement string. Note that source
         * ranges are half-open ranges [a, b), so the source code should be
         * replaced from a and up to (but not including) b.
         *
         * \returns A string containing text that should be replace the source
         * code indicated by the \c ReplacementRange.
         */
        CXString (*clang_getDiagnosticFixIt)(CXDiagnostic Diagnostic,
                                             unsigned FixIt,
                                             CXSourceRange *ReplacementRange);

        // MARK: CAS

        /**
         * Configuration options for ObjectStore and ActionCache.
         */
        typedef struct CXOpaqueCASOptions *CXCASOptions;

        /**
         * Encapsulates instances of ObjectStore and ActionCache, created from a
         * particular configuration of \p CXCASOptions.
         */
        typedef struct CXOpaqueCASDatabases *CXCASDatabases;

        typedef struct CXOpaqueCASObject *CXCASObject;

        /**
         * Result of \c clang_experimental_cas_getCachedCompilation.
         */
        typedef struct CXOpaqueCASCachedCompilation *CXCASCachedCompilation;

        /**
         * Result of \c clang_experimental_cas_replayCompilation.
         */
        typedef struct CXOpaqueCASReplayResult *CXCASReplayResult;

        /**
         * Used for cancelling asynchronous actions.
         */
        typedef struct CXOpaqueCASCancellationToken *CXCASCancellationToken;

        /**
         * Create a \c CXCASOptions object.
         */
        CXCASOptions (*clang_experimental_cas_Options_create)(void);

        /**
         * Dispose of a \c CXCASOptions object.
         */
        void (*clang_experimental_cas_Options_dispose)(CXCASOptions);

        /**
         * Configure the file path to use for on-disk CAS/cache instances.
         */
        void (*clang_experimental_cas_Options_setOnDiskPath)(CXCASOptions, const char *Path);

        /**
         * Configure the path to a library that implements the LLVM CAS plugin API.
         */
        void (*clang_experimental_cas_Options_setPluginPath)(CXCASOptions, const char *Path);

        /**
         * Set a value for a named option that the CAS plugin supports.
         */
        void (*clang_experimental_cas_Options_setPluginOption)(CXCASOptions, const char *Name, const char *Value);

        /**
         * Creates instances for a CAS object store and action cache based on the
         * configuration of a \p CXCASOptions.
         *
         * \param Opts configuration options.
         * \param[out] Error The error string to pass back to client (if any).
         *
         * \returns The resulting instances object, or null if there was an error.
         */
        CXCASDatabases (*clang_experimental_cas_Databases_create)(CXCASOptions, CXString *Error);

        /**
         * Dispose of a \c CXCASDatabases object.
         */
        void (*clang_experimental_cas_Databases_dispose)(CXCASDatabases);

        /**
         * Get the local storage size of the CAS/cache data in bytes.
         *
         * \param[out] OutError The error object to pass back to client (if any).
         * If non-null the object must be disposed using \c clang_Error_dispose.
         * \returns the local storage size of the CAS/cache data, or -1 if the
         * implementation does not support reporting such size, or -2 if an error
         * occurred.
         */
        int64_t (*clang_experimental_cas_Databases_get_storage_size)(
            CXCASDatabases, CXError *OutError);

        /**
         * Set the size for limiting disk storage growth.
         *
         * \param size_limit the maximum size limit in bytes. 0 means no limit. Negative
         * values are invalid.
         * \returns an error object if there was an error, NULL otherwise.
         * If non-null the object must be disposed using \c clang_Error_dispose.
         */
        CXError (*clang_experimental_cas_Databases_set_size_limit)(
            CXCASDatabases, int64_t size_limit);

        /**
         * Prune local storage to reduce its size according to the desired size limit.
         * Pruning can happen concurrently with other operations.
         *
         * \returns an error object if there was an error, NULL otherwise.
         * If non-null the object must be disposed using \c clang_Error_dispose.
         */
        CXError (*clang_experimental_cas_Databases_prune_ondisk_data)(CXCASDatabases);

        /**
         * Checks whether an object is materialized using its printed \p CASID.
         * @param CASID The printed CASID string for the object.
         * @param[out] OutError The error object to pass back to client (if any).
         * If non-null the object must be disposed using \c clang_Error_dispose.
         *
         * @return True when the object is materialized in the database, false if not.
         */
        bool (*clang_experimental_cas_isMaterialized)(CXCASDatabases,
                                                      const char *CASID,
                                                      CXError *OutError);

        /**
         * Loads an object using its printed \p CASID.
         *
         * \param CASID The printed CASID string for the object.
         * \param[out] OutError The error object to pass back to client (if any).
         * If non-null the object must be disposed using \c clang_Error_dispose.
         *
         * \returns The resulting object, or null if the object was not found or an
         * error occurred. The object should be disposed using
         * \c clang_experimental_cas_CASObject_dispose.
         */
        CXCASObject (*clang_experimental_cas_loadObjectByString)(
            CXCASDatabases, const char *CASID, CXError *OutError);

        /**
         * Asynchronous version of \c clang_experimental_cas_loadObjectByString.
         *
         * \param CASID The printed CASID string for the object.
         * \param Ctx opaque value to pass to the callback.
         * \param Callback receives a \c CXCASObject, or \c CXError if an error occurred
         * or both NULL if the object was not found or the call was cancelled.
         * The objects should be disposed with
         * \c clang_experimental_cas_CASObject_dispose or \c clang_Error_dispose.
         * \param[out] OutToken if non-null receives a \c CXCASCancellationToken that
         * can be used to cancel the call using
         * \c clang_experimental_cas_CancellationToken_cancel. The object should be
         * disposed using \c clang_experimental_cas_CancellationToken_dispose.
         */
        void (*clang_experimental_cas_loadObjectByString_async)(
            CXCASDatabases, const char *CASID, void *Ctx,
            void (*Callback)(void *Ctx, CXCASObject, CXError),
            CXCASCancellationToken *OutToken);

        /**
         * Dispose of a \c CXCASObject object.
         */
        void (*clang_experimental_cas_CASObject_dispose)(CXCASObject);

        /**
         * Looks up a cache key and returns the associated set of compilation output IDs
         *
         * \param CacheKey The printed compilation cache key string.
         * \param Globally if true it is a hint to the underlying CAS implementation
         * that the lookup is profitable to be done on a distributed caching level, not
         * just locally.
         * \param[out] OutError The error object to pass back to client (if any).
         * If non-null the object must be disposed using \c clang_Error_dispose.
         *
         * \returns The resulting object, or null if the cache key was not found or an
         * error occurred. The object should be disposed using
         * \c clang_experimental_cas_CachedCompilation_dispose.
         */
        CXCASCachedCompilation
        (*clang_experimental_cas_getCachedCompilation)(CXCASDatabases,
                                                       const char *CacheKey, bool Globally,
                                                       CXError *OutError);

        /**
         * Asynchronous version of \c clang_experimental_cas_getCachedCompilation.
         *
         * \param CacheKey The printed compilation cache key string.
         * \param Globally if true it is a hint to the underlying CAS implementation
         * that the lookup is profitable to be done on a distributed caching level, not
         * just locally.
         * \param Ctx opaque value to pass to the callback.
         * \param Callback receives a \c CXCASCachedCompilation, or \c CXError if an
         * error occurred or both NULL if the object was not found or the call was
         * cancelled. The objects should be disposed with
         * \c clang_experimental_cas_CachedCompilation_dispose or \c clang_Error_dispose
         * \param[out] OutToken if non-null receives a \c CXCASCancellationToken that
         * can be used to cancel the call using
         * \c clang_experimental_cas_CancellationToken_cancel. The object should be
         * disposed using \c clang_experimental_cas_CancellationToken_dispose.
         */
        void (*clang_experimental_cas_getCachedCompilation_async)(
            CXCASDatabases, const char *CacheKey, bool Globally, void *Ctx,
            void (*Callback)(void *Ctx, CXCASCachedCompilation, CXError),
            CXCASCancellationToken *OutToken);

        /**
         * Dispose of a \c CXCASCachedCompilation object.
         */
        void (*clang_experimental_cas_CachedCompilation_dispose)(CXCASCachedCompilation);

        /**
         * \returns number of compilation outputs.
         */
        size_t (*clang_experimental_cas_CachedCompilation_getNumOutputs)(CXCASCachedCompilation);

        /**
         * \returns the compilation output name given the index via \p OutputIdx.
         */
        CXString (*clang_experimental_cas_CachedCompilation_getOutputName)(
            CXCASCachedCompilation, size_t OutputIdx);

        /**
         * \returns the compilation output printed CASID given the index via \p OutputIdx.
         */
        CXString (*clang_experimental_cas_CachedCompilation_getOutputCASIDString)(
            CXCASCachedCompilation, size_t OutputIdx);

        /**
         * \returns whether the compilation output data exist in the local CAS given the
         * index via \p OutputIdx.
         */
        bool (*clang_experimental_cas_CachedCompilation_isOutputMaterialized)(
            CXCASCachedCompilation, size_t OutputIdx);

        /**
         * If distributed caching is available it uploads the compilation outputs and
         * the association of key <-> outputs to the distributed cache.
         * This allows separating the task of computing the compilation outputs and
         * storing them in the local cache, from the task of "uploading" them.
         *
         * \param Ctx opaque value to pass to the callback.
         * \param Callback receives a \c CXError if an error occurred. The error will be
         * NULL if the call was successful or cancelled. The error should be disposed
         * via \c clang_Error_dispose.
         * \param[out] OutToken if non-null receives a \c CXCASCancellationToken that
         * can be used to cancel the call using
         * \c clang_experimental_cas_CancellationToken_cancel. The object should be
         * disposed using \c clang_experimental_cas_CancellationToken_dispose.
         */
        void (*clang_experimental_cas_CachedCompilation_makeGlobal)(
            CXCASCachedCompilation, void *Ctx, void (*Callback)(void *Ctx, CXError),
            CXCASCancellationToken *OutToken);

        /**
         * Replays a cached compilation using the cached outputs and the given
         * compilation arguments.
         *
         * \param argc number of compilation arguments.
         * \param argv array of compilation arguments.
         * \param WorkingDirectory working directory to use, can be NULL.
         * \param reserved for future use, caller must pass NULL.
         * \param[out] OutError The error object to pass back to client (if any).
         * If non-null the object must be disposed using \c clang_Error_dispose.
         *
         * \returns a \c CXCASReplayResult object or NULL if an error occurred or a
         * compilation output was not found in the CAS. The object should be disposed
         * via \c clang_experimental_cas_ReplayResult_dispose.
         */
        CXCASReplayResult (*clang_experimental_cas_replayCompilation)(
            CXCASCachedCompilation, int argc, const char *const *argv,
            const char *WorkingDirectory, void *reserved, CXError *OutError);

        /**
         * Dispose of a \c CXCASReplayResult object.
         */
        void (*clang_experimental_cas_ReplayResult_dispose)(CXCASReplayResult);

        /**
         * Get the diagnostic text of a replayed cached compilation.
         */
        CXString (*clang_experimental_cas_ReplayResult_getStderr)(CXCASReplayResult);

        /**
         * Cancel an asynchronous CAS-related action.
         */
        void (*clang_experimental_cas_CancellationToken_cancel)(CXCASCancellationToken);

        /**
         * Dispose of a \c CXCASCancellationToken object.
         */
        void (*clang_experimental_cas_CancellationToken_dispose)(CXCASCancellationToken);

        // MARK: Dependency Scanner

        /**
         * Object encapsulating instance of a dependency scanner service.
         *
         * The dependency scanner service is a global instance that is owns the
         * global cache and other global state that's shared between the dependency
         * scanner workers. The service APIs are thread safe.
         */
        typedef struct CXOpaqueDependencyScannerService
            *CXDependencyScannerService;

        /**
         * Object encapsulating instance of a dependency scanner worker.
         *
         * The dependency scanner workers are expected to be used in separate worker
         * threads. An individual worker is not thread safe.
         */
        typedef struct CXOpaqueDependencyScannerWorker
            *CXDependencyScannerWorker;

        // MARK: Experimental ScanDeps API

        /**
         * An output file kind needed by module dependencies.
         */
        typedef enum {
          CXOutputKind_ModuleFile = 0,
          CXOutputKind_Dependencies = 1,
          CXOutputKind_DependenciesTarget = 2,
          CXOutputKind_SerializedDiagnostics = 3,
        } CXOutputKind;

        /**
         * The mode to report module dependencies in.
         */
        typedef enum {
            /**
             * Flatten all module dependencies. This reports the full transitive
             * set of header and module map dependencies needed to do an
             * implicit module build.
             */
            CXDependencyMode_Flat,

            /**
             * Report the full module graph. This reports only the direct
             * dependencies of each file, and calls a callback for each module
             * that is discovered.
             */
            CXDependencyMode_Full,
        } CXDependencyMode;

        /**
         * Options used to construct a \c CXDependencyScannerService.
         */
        typedef struct CXOpaqueDependencyScannerServiceOptions
            *CXDependencyScannerServiceOptions;

        /**
         * Creates a default set of service options.
         * Must be disposed with \c
         * clang_experimental_DependencyScannerServiceOptions_dispose.
         */
        CXDependencyScannerServiceOptions
        (*clang_experimental_DependencyScannerServiceOptions_create)();

        /**
         * Dispose of a \c CXDependencyScannerServiceOptions object.
         */
        void (*clang_experimental_DependencyScannerServiceOptions_dispose)(
            CXDependencyScannerServiceOptions);

        /**
         * Specify a \c CXDependencyMode in the given options.
         */
        void
        (*clang_experimental_DependencyScannerServiceOptions_setDependencyMode)(
            CXDependencyScannerServiceOptions Opts, CXDependencyMode Mode);

        /**
         * Specify the object store and action cache databases in the given options.
         * With this set, the scanner will produce cached commands.
         */
        void (*clang_experimental_DependencyScannerServiceOptions_setCASDatabases)(CXDependencyScannerServiceOptions Opts, CXCASDatabases);

        /**
         * Specify the specific CAS options for the scanner to use for the produced
         * compiler arguments.
         */
        void (*clang_experimental_DependencyScannerServiceOptions_setCASOptions)(CXDependencyScannerServiceOptions Opts, CXCASOptions);

        /**
          * Set the working directory optimization option.
          * The dependency scanner service option Opts will indicate to the scanner that
          * the current working directory can or cannot be ignored when computing the
          * pcms' context hashes. The scanner will then determine if it is safe to
          * optimize each module and act accordingly.
          *
          * \param Value If it is non zero, the option is on. Otherwise the
          * option is off.
          */
        void (*clang_experimental_DependencyScannerServiceOptions_setCWDOptimization)(CXDependencyScannerServiceOptions Opts, int Value);

        /**
         * Create a \c CXDependencyScannerService object.
         * Must be disposed with \c clang_experimental_DependencyScannerService_dispose_v0().
         */
        CXDependencyScannerService
        (*clang_experimental_DependencyScannerService_create_v1)(CXDependencyScannerServiceOptions);

        /**
         * Dispose of a \c CXDependencyScannerService object.
         *
         * The service object must be disposed of after the workers are disposed
         * of.
         */
        void (*clang_experimental_DependencyScannerService_dispose_v0)(
            CXDependencyScannerService);

        /**
         * Create a \c CXDependencyScannerWorker object.
         *
         * Must be disposed with
         * \c clang_experimental_DependencyScannerWorker_dispose_v0.
         */
        CXDependencyScannerWorker (
            *clang_experimental_DependencyScannerWorker_create_v0)(
            CXDependencyScannerService);

        /**
         * Dispose of a \c CXDependencyScannerWorker object.
         *
         * The worker objects must be disposed of before the service is disposed
         * of.
         */
        void (*clang_experimental_DependencyScannerWorker_dispose_v0)(
            CXDependencyScannerWorker);

        /**
         * A callback that is called to determine the paths of output files for each
         * module dependency. The ModuleFile (pcm) path mapping is mandatory.
         *
         * \param Context the MLOContext that was passed to
         *         \c clang_experimental_DependencyScannerWorker_getFileDependencies_vX.
         * \param ModuleName the name of the dependent module.
         * \param ContextHash the context hash of the dependent module.
         *                    See \c CXModuleDependency::ContextHash.
         & \param OutputKind the kind of module output to lookup.
         * \param Output[out] the output path(s) or name, whose total size must be <=
         *                    \p MaxLen. In the case of multiple outputs of the same
         *                    kind, this can be a null-separated list.
         * \param MaxLen the maximum size of Output.
         *
         * \returns the actual length of Output. If the return value is > \p MaxLen,
         *          the callback will be repeated with a larger buffer.
         */
        typedef size_t CXModuleLookupOutputCallback(void *Context,
                                                    const char *ModuleName,
                                                    const char *ContextHash,
                                                    CXOutputKind OutputKind,
                                                    char *Output, size_t MaxLen);

        /**
         * Output of \c clang_experimental_DependencyScannerWorker_getDepGraph.
         */
        typedef struct CXOpaqueDepGraph *CXDepGraph;

        /**
         * An individual module dependency that is part of an overall compilation
         * \c CXDepGraph.
         */
        typedef struct CXOpaqueDepGraphModule *CXDepGraphModule;

        /**
         * An individual command-line invocation that is part of an overall compilation
         * \c CXDepGraph.
         */
        typedef struct CXOpaqueDepGraphTUCommand *CXDepGraphTUCommand;

        /**
         * Settings to use for the
         * \c clang_experimental_DependencyScannerWorker_getDepGraph action.
         */
        typedef struct CXOpaqueDependencyScannerWorkerScanSettings
            *CXDependencyScannerWorkerScanSettings;

        /**
         * Creates a set of settings for
         * \c clang_experimental_DependencyScannerWorker_getDepGraph action.
         * Must be disposed with
         * \c clang_experimental_DependencyScannerWorkerScanSettings_dispose.
         * Memory for settings is not copied. Any provided pointers must be valid until
         * the call to \c clang_experimental_DependencyScannerWorker_getDepGraph.
         *
         * \param argc the number of compiler invocation arguments (including argv[0]).
         * \param argv the compiler driver invocation arguments (including argv[0]).
         * \param ModuleName If non-null, the dependencies of the named module are
         *                   returned. Otherwise, the dependencies of the whole
         *                   translation unit are returned.
         * \param WorkingDirectory the directory in which the invocation runs.
         * \param MLOContext the context that will be passed to \c MLO each time it is
         *                   called.
         * \param MLO a callback that is called to determine the paths of output files
         *            for each module dependency. This may receive the same module on
         *            different workers. This should be NULL if
         *            \c clang_experimental_DependencyScannerService_create_v1 was
         *            called with \c CXDependencyMode_Flat. This callback will be called
         *            on the same thread that called \c
         *            clang_experimental_DependencyScannerWorker_getDepGraph.
         */
        CXDependencyScannerWorkerScanSettings
        (*clang_experimental_DependencyScannerWorkerScanSettings_create)(
            int argc, const char *const *argv, const char *ModuleName,
            const char *WorkingDirectory, void *MLOContext,
            CXModuleLookupOutputCallback *MLO);

        /**
         * Dispose of a \c CXDependencyScannerWorkerScanSettings object.
         */
        void (*clang_experimental_DependencyScannerWorkerScanSettings_dispose)(
                CXDependencyScannerWorkerScanSettings);

        /**
         * Produces the dependency graph for a particular compiler invocation.
         *
         * \param Settings object created via
         *     \c clang_experimental_DependencyScannerWorkerScanSettings_create.
         * \param [out] Out A non-NULL pointer to store the resulting dependencies. The
         *                  output must be freed by calling
         *                  \c clang_experimental_DepGraph_dispose.
         *
         * \returns \c CXError_Success on success; otherwise a non-zero \c CXErrorCode
         * indicating the kind of error. When returning \c CXError_Failure there will
         * be a \c CXDepGraph object on \p Out that can be used to get diagnostics via
         * \c clang_experimental_DepGraph_getDiagnostics.
         */
        enum CXErrorCode
        (*clang_experimental_DependencyScannerWorker_getDepGraph)(
            CXDependencyScannerWorker, CXDependencyScannerWorkerScanSettings Settings,
            CXDepGraph *Out);

        /**
         * Dispose of a \c CXDepGraph object.
         */
        void (*clang_experimental_DepGraph_dispose)(CXDepGraph);

        /**
         * \returns the number of \c CXDepGraphModule objects in the graph.
         */
        size_t (*clang_experimental_DepGraph_getNumModules)(CXDepGraph);

        /**
         * \returns the \c CXDepGraphModule object at the given \p Index.
         *
         * The \c CXDepGraphModule object is only valid to use while \c CXDepGraph is
         * valid. Must be disposed with \c clang_experimental_DepGraphModule_dispose.
         */
        CXDepGraphModule
        (*clang_experimental_DepGraph_getModule)(CXDepGraph, size_t Index);

        /**
         * \returns the \c CXDepGraphModule object at the given \p Index in
         * a topologically sorted list.
         *
         * The \c CXDepGraphModule object is only valid to use while \c CXDepGraph is
         * valid. Must be disposed with \c clang_experimental_DepGraphModule_dispose.
         */
       CXDepGraphModule
       (*clang_experimental_DepGraph_getModuleTopological)(CXDepGraph, size_t Index);

        void (*clang_experimental_DepGraphModule_dispose)(CXDepGraphModule);

        /**
         * \returns the name of the module. This may include `:` for C++20 module
         * partitions, or a header-name for C++20 header units.
         *
         * The string is only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphModule_getName)(CXDepGraphModule);

        /**
         * \returns the context hash of a module represents the set of compiler options
         * that may make one version of a module incompatible from another. This
         * includes things like language mode, predefined macros, header search paths,
         * etc...
         *
         * Modules with the same name but a different \c ContextHash should be treated
         * as separate modules for the purpose of a build.
         *
         * The string is only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphModule_getContextHash)(CXDepGraphModule);

        /**
         * \returns the path to the modulemap file which defines this module. If there's
         * no modulemap (e.g. for a C++ module) returns \c NULL.
         *
         * This can be used to explicitly build this module. This file will
         * additionally appear in \c FileDeps as a dependency.
         *
         * The string is only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphModule_getModuleMapPath)(CXDepGraphModule);

        /**
         * \returns the list of files which this module directly depends on.
         *
         * If any of these change then the module needs to be rebuilt.
         *
         * The strings are only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        CXCStringArray (*clang_experimental_DepGraphModule_getFileDeps)(CXDepGraphModule);

        /**
         * \returns the list of modules which this module direct depends on.
         *
         * This does include the context hash. The format is
         * `<module-name>:<context-hash>`
         *
         * The strings are only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        CXCStringArray (*clang_experimental_DepGraphModule_getModuleDeps)(CXDepGraphModule);

        /**
         * \returns the canonical command line to build this module.
         *
         * The strings are only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        CXCStringArray (*clang_experimental_DepGraphModule_getBuildArguments)(CXDepGraphModule);

        /**
         * @returns the CASID of the include-tree for this module, if any.
         *
         * The string is only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphModule_getIncludeTreeID)(CXDepGraphModule);

        /**
         * \returns the \c ActionCache key for this module, if any.
         *
         * The string is only valid to use while the \c CXDepGraphModule object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphModule_getCacheKey)(CXDepGraphModule);

        /**
          * \returns 1 if the scanner ignores the current working directory when
          * computing the module's context hash. Otherwise returns 0.
          */
         int (*clang_experimental_DepGraphModule_isCWDIgnored)(CXDepGraphModule);

        /**
         * \returns the number \c CXDepGraphTUCommand objects in the graph.
         */
        size_t (*clang_experimental_DepGraph_getNumTUCommands)(CXDepGraph);

        /**
         * \returns the \c CXDepGraphTUCommand object at the given \p Index.
         *
         * The \c CXDepGraphTUCommand object is only valid to use while \c CXDepGraph is
         * valid. Must be disposed with \c clang_experimental_DepGraphTUCommand_dispose.
         */
        CXDepGraphTUCommand
        (*clang_experimental_DepGraph_getTUCommand)(CXDepGraph, size_t Index);

        /**
         * Dispose of a \c CXDepGraphTUCommand object.
         */
        void (*clang_experimental_DepGraphTUCommand_dispose)(CXDepGraphTUCommand);

        /**
         * \returns the executable name for the command.
         *
         * The string is only valid to use while the \c CXDepGraphTUCommand object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphTUCommand_getExecutable)(CXDepGraphTUCommand);

        /**
         * \returns the canonical command line to build this translation unit.
         *
         * The strings are only valid to use while the \c CXDepGraphTUCommand object is
         * valid.
         */
        CXCStringArray (*clang_experimental_DepGraphTUCommand_getBuildArguments)(CXDepGraphTUCommand);

        /**
         * \returns the \c ActionCache key for this translation unit, if any.
         *
         * The string is only valid to use while the \c CXDepGraphTUCommand object is
         * valid.
         */
        const char *(*clang_experimental_DepGraphTUCommand_getCacheKey)(CXDepGraphTUCommand);

        /**
         * \returns the list of files which this translation unit directly depends on.
         *
         * The strings are only valid to use while the \c CXDepGraph object is valid.
         */
        CXCStringArray (*clang_experimental_DepGraph_getTUFileDeps)(CXDepGraph);

        /**
         * \returns the list of modules which this translation unit direct depends on.
         *
         * This does include the context hash. The format is
         * `<module-name>:<context-hash>`
         *
         * The strings are only valid to use while the \c CXDepGraph object is valid.
         */
        CXCStringArray (*clang_experimental_DepGraph_getTUModuleDeps)(CXDepGraph);

        /**
         * @returns the CASID of the include-tree for this TU, if any.
         *
         * The string is only valid to use while the \c CXDepGraph object is valid.
         */
        const char *(*clang_experimental_DepGraph_getTUIncludeTreeID)(CXDepGraph);

        /**
         * \returns the context hash of the C++20 module this translation unit exports.
         *
         * If the translation unit is not a module then this is empty.
         *
         * The string is only valid to use while the \c CXDepGraph object is valid.
         */
        const char *(*clang_experimental_DepGraph_getTUContextHash)(CXDepGraph);

        /**
         * \returns The diagnostics emitted during scanning. These must be always freed
         * by calling \c clang_disposeDiagnosticSet.
         */
        CXDiagnosticSet (*clang_experimental_DepGraph_getDiagnostics)(CXDepGraph);

        // MARK: Driver API

        /**
         * Contains the command line arguments for an external action.  Same format as provided to main.
         */
        typedef struct {
          /* Number of arguments in ArgV */
          int ArgC;
          /* Null terminated array of pointers to null terminated argument strings */
          const char **ArgV;
        } CXExternalAction;

        /**
         * Contains the list of external actions clang would invoke.
         */
        typedef struct {
          int Count;
          CXExternalAction **Actions;
        } CXExternalActionList;

        /**
         * Get the external actions that the clang driver will invoke for the given
         * command line.
         *
         * \param ArgC number of arguments in \p ArgV.
         * \param ArgV array of null terminated arguments.  Doesn't need to be null
         *   terminated.
         * \param Environment must be null.
         * \param WorkingDirectory a null terminated path to the working directory to
         *   use for this invocation.  `nullptr` to use the current working directory of
         *   the process.
         * \param OutDiags will be set to a \c CXDiagnosticSet if there's an error.
         *   Must be freed by calling \c clang_disposeDiagnosticSet .
         * \returns A pointer to a \c CXExternalActionList on success, null on failure.
         *   The returned \c CXExternalActionList must be freed by calling
         *   \c clang_Driver_ExternalActionList_dispose .
         */
        CXExternalActionList *
        (*clang_Driver_getExternalActionsForCommand_v0)(int ArgC, const char **ArgV,
                                                        const char **Environment,
                                                        const char *WorkingDirectory,
                                                        CXDiagnosticSet *OutDiags);
        /**
         * Deallocate a \c CXExternalActionList
         */
        void
        (*clang_Driver_ExternalActionList_dispose)(CXExternalActionList *EAL);


        /**
         * Installs error handler that prints error message to stderr and calls abort().
         * Replaces currently installed error handler (if any).
         */
        void (*clang_install_aborting_llvm_fatal_error_handler)();
    };
}

namespace {

struct LibclangScanner;

struct LibclangWrapper {
    /// The original path of the library;
    std::string path;

    /// The dynamic library handle.
    LOOKUP_HANDLE_TYPE handle;

    /// Whether or not this instance has been explicitly leaked.
    bool isLeaked;

    /// Wrapper functions.
    LibclangFunctions fns;

    bool hasRequiredAPI;
    bool hasDependencyScanner;
    bool hasStructuredScanningDiagnostics;
    bool hasCAS;

    LibclangWrapper(std::string path)
        : path(path),
#ifdef _WIN32
          handle(nullptr),
#elif defined(__APPLE__)
          // Use RTLD_LOCAL/RTLD_FIRST because we may load more than one copy of libclang, and we don't want to mix and match symbols from more than one library in one wrapper instance.
          handle(dlopen(path.c_str(), RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST)),
#else
          handle(dlopen(path.c_str(), RTLD_LAZY | RTLD_LOCAL)),
#endif
          isLeaked(false), hasRequiredAPI(true), hasDependencyScanner(true), hasStructuredScanningDiagnostics(true), hasCAS(true) {
#if defined(_WIN32)
        DWORD cchLength = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.c_str(), -1, nullptr, 0);
        std::unique_ptr<wchar_t[]> wszPath(new wchar_t[cchLength]);
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.c_str(), -1, wszPath.get(), cchLength))
            return;
        handle = LoadLibraryW(wszPath.get());
#endif

        if (!handle) return;

#define LOOKUP(name) ({                                 \
                auto fn = LOOKUP_FN(handle, #name);     \
                if (!fn) {                              \
                    hasRequiredAPI = false;             \
                    return;                             \
                }                                       \
                fns.name = (decltype(fns.name)) fn;     \
            })
#define LOOKUP_OPTIONAL(name) ({                        \
                auto fn = LOOKUP_FN(handle, #name);     \
                fns.name = (decltype(fns.name)) fn;     \
            })
#define LOOKUP_OPTIONAL_DEPENDENCY_SCANNER_API(name) ({ \
                auto fn = LOOKUP_FN(handle, #name);     \
                fns.name = (decltype(fns.name)) fn;     \
                if (!fn) {                              \
                    hasDependencyScanner = false;       \
                }                                       \
            })
#define LOOKUP_OPTIONAL_CAS_API(name) ({                \
                auto fn = LOOKUP_FN(handle, #name);     \
                fns.name = (decltype(fns.name)) fn;     \
                if (!fn) {                              \
                    hasCAS = false;                     \
                }                                       \
            })
        LOOKUP(clang_getCString);
        LOOKUP(clang_disposeString);
        LOOKUP(clang_disposeStringSet);
        LOOKUP(clang_getClangVersion);
        LOOKUP_OPTIONAL(clang_Error_dispose);
        LOOKUP_OPTIONAL(clang_Error_getCode);
        LOOKUP_OPTIONAL(clang_Error_getDescription);

        LOOKUP(clang_getFileName);
        LOOKUP(clang_getSpellingLocation);
        LOOKUP(clang_getRangeStart);
        LOOKUP(clang_getRangeEnd);
        LOOKUP(clang_getNumDiagnosticsInSet);
        LOOKUP(clang_getDiagnosticInSet);
        LOOKUP(clang_loadDiagnostics);
        LOOKUP(clang_disposeDiagnosticSet);
        LOOKUP(clang_getChildDiagnostics);
        LOOKUP(clang_disposeDiagnostic);
        LOOKUP(clang_formatDiagnostic);
        LOOKUP(clang_defaultDiagnosticDisplayOptions);
        LOOKUP(clang_getDiagnosticSeverity);
        LOOKUP(clang_getDiagnosticLocation);
        LOOKUP(clang_getDiagnosticSpelling);
        LOOKUP(clang_getDiagnosticOption);
        LOOKUP(clang_getDiagnosticCategory);
        LOOKUP(clang_getDiagnosticCategoryText);
        LOOKUP(clang_getDiagnosticNumRanges);
        LOOKUP(clang_getDiagnosticRange);
        LOOKUP(clang_getDiagnosticNumFixIts);
        LOOKUP(clang_getDiagnosticFixIt);

        LOOKUP_OPTIONAL_CAS_API(clang_experimental_cas_Databases_create);
        LOOKUP_OPTIONAL_CAS_API(clang_experimental_cas_Databases_dispose);
        LOOKUP_OPTIONAL_CAS_API(clang_experimental_cas_Options_create);
        LOOKUP_OPTIONAL_CAS_API(clang_experimental_cas_Options_dispose);
        LOOKUP_OPTIONAL_CAS_API(clang_experimental_cas_Options_setOnDiskPath);
        LOOKUP_OPTIONAL(clang_experimental_cas_Options_setPluginOption);
        LOOKUP_OPTIONAL(clang_experimental_cas_Options_setPluginPath);
        LOOKUP_OPTIONAL(clang_experimental_cas_CachedCompilation_dispose);
        LOOKUP_OPTIONAL(clang_experimental_cas_CachedCompilation_getNumOutputs);
        LOOKUP_OPTIONAL(clang_experimental_cas_CachedCompilation_getOutputCASIDString);
        LOOKUP_OPTIONAL(clang_experimental_cas_CachedCompilation_getOutputName);
        LOOKUP_OPTIONAL(clang_experimental_cas_CachedCompilation_isOutputMaterialized);
        LOOKUP_OPTIONAL(clang_experimental_cas_CachedCompilation_makeGlobal);
        LOOKUP_OPTIONAL(clang_experimental_cas_CASObject_dispose);
        LOOKUP_OPTIONAL(clang_experimental_cas_Databases_get_storage_size);
        LOOKUP_OPTIONAL(clang_experimental_cas_Databases_set_size_limit);
        LOOKUP_OPTIONAL(clang_experimental_cas_Databases_prune_ondisk_data);
        LOOKUP_OPTIONAL(clang_experimental_cas_getCachedCompilation);
        LOOKUP_OPTIONAL(clang_experimental_cas_getCachedCompilation_async);
        LOOKUP_OPTIONAL(clang_experimental_cas_isMaterialized);
        LOOKUP_OPTIONAL(clang_experimental_cas_loadObjectByString);
        LOOKUP_OPTIONAL(clang_experimental_cas_loadObjectByString_async);
        LOOKUP_OPTIONAL(clang_experimental_cas_replayCompilation);
        LOOKUP_OPTIONAL(clang_experimental_cas_ReplayResult_dispose);
        LOOKUP_OPTIONAL(clang_experimental_cas_ReplayResult_getStderr);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerServiceOptions_create);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerServiceOptions_dispose);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerServiceOptions_setDependencyMode);
        LOOKUP_OPTIONAL_CAS_API(clang_experimental_DependencyScannerServiceOptions_setCASDatabases);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerServiceOptions_setCASOptions);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerServiceOptions_setCWDOptimization);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerService_create_v1);
        LOOKUP_OPTIONAL_DEPENDENCY_SCANNER_API(clang_experimental_DependencyScannerService_dispose_v0);
        LOOKUP_OPTIONAL_DEPENDENCY_SCANNER_API(clang_experimental_DependencyScannerWorker_create_v0);
        LOOKUP_OPTIONAL_DEPENDENCY_SCANNER_API(clang_experimental_DependencyScannerWorker_dispose_v0);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerWorkerScanSettings_create);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerWorkerScanSettings_dispose);
        LOOKUP_OPTIONAL(clang_experimental_DependencyScannerWorker_getDepGraph);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_dispose);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getNumModules);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getModule);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getModuleTopological);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_dispose);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getName);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getContextHash);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getModuleMapPath);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getFileDeps);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getModuleDeps);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getBuildArguments);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getCacheKey);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_isCWDIgnored);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphModule_getIncludeTreeID);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getNumTUCommands);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getTUCommand);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphTUCommand_dispose);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphTUCommand_getExecutable);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphTUCommand_getBuildArguments);
        LOOKUP_OPTIONAL(clang_experimental_DepGraphTUCommand_getCacheKey);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getTUIncludeTreeID);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getTUFileDeps);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getTUModuleDeps);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getTUContextHash);
        LOOKUP_OPTIONAL(clang_experimental_DepGraph_getDiagnostics);
        if (!fns.clang_experimental_DependencyScannerWorker_getDepGraph) {
            hasDependencyScanner = false;
            hasStructuredScanningDiagnostics = false;
            hasCAS = false;
        }

        LOOKUP_OPTIONAL(clang_Driver_getExternalActionsForCommand_v0);
        LOOKUP_OPTIONAL(clang_Driver_ExternalActionList_dispose);
        LOOKUP_OPTIONAL(clang_install_aborting_llvm_fatal_error_handler);
#undef LOOKUP
#undef LOOKUP_OPTIONAL
#undef LOOKUP_OPTIONAL_DEPENDENCY_SCANNER_API

        // If possible, install the datal error handler.
        if (fns.clang_install_aborting_llvm_fatal_error_handler) {
          fns.clang_install_aborting_llvm_fatal_error_handler();
        }
    }

    void leak() {
        isLeaked = true;
    }

    ~LibclangWrapper() {
        // Abort if the client has not explicitly leaked the interface to libclang.
        if (handle && !isLeaked)
            abort();
    }
};

struct ScannerWorker {
    LibclangWrapper* lib;

    LibclangFunctions::CXDependencyScannerWorker worker;

    ScannerWorker(LibclangWrapper* lib,
                  LibclangFunctions::CXDependencyScannerService service)
        : lib(lib)
    {
        worker = lib->fns.clang_experimental_DependencyScannerWorker_create_v0(
            service);
        assert(worker && "unable to create worker");
    }

    ~ScannerWorker() {
        lib->fns.clang_experimental_DependencyScannerWorker_dispose_v0(worker);
    }
};

struct LibclangCASOptions {
    LibclangWrapper* lib;
    LibclangFunctions::CXCASOptions casOpts;

    void setOnDiskPath(const char *path) {
        lib->fns.clang_experimental_cas_Options_setOnDiskPath(casOpts, path);
    }

    /// \c libclang_has_cas_plugin_feature should be true before calling.
    void setPluginPath(const char *path) {
        lib->fns.clang_experimental_cas_Options_setPluginPath(casOpts, path);
    }

    /// \c libclang_has_cas_plugin_feature should be true before calling.
    void setPluginOption(const char *name, const char *value) {
        lib->fns.clang_experimental_cas_Options_setPluginOption(casOpts, name, value);
    }

    LibclangCASOptions(LibclangWrapper* lib, LibclangFunctions::CXCASOptions opts) : lib(lib), casOpts(opts) {}

    ~LibclangCASOptions() {
        lib->fns.clang_experimental_cas_Options_dispose(casOpts);
    }
};

struct LibclangCASDatabases {
    LibclangWrapper* lib;
    LibclangFunctions::CXCASDatabases casDBs = nullptr;

    LibclangCASDatabases(LibclangWrapper* lib,
                         LibclangFunctions::CXCASDatabases casDBs) : lib(lib), casDBs(casDBs) {}

    ~LibclangCASDatabases() {
        lib->fns.clang_experimental_cas_Databases_dispose(casDBs);
    }
};

struct LibclangCASObject {
    LibclangWrapper* lib;
    LibclangFunctions::CXCASObject cxObj = nullptr;

    LibclangCASObject(LibclangWrapper* lib,
                      LibclangFunctions::CXCASObject cxObj) : lib(lib), cxObj(cxObj) {}

    ~LibclangCASObject() {
        lib->fns.clang_experimental_cas_CASObject_dispose(cxObj);
    }
};

struct LibclangCASCachedCompilation {
    LibclangWrapper* lib;
    LibclangFunctions::CXCASCachedCompilation cxComp = nullptr;

    LibclangCASCachedCompilation(LibclangWrapper* lib,
                                 LibclangFunctions::CXCASCachedCompilation cxComp) : lib(lib), cxComp(cxComp) {}

    ~LibclangCASCachedCompilation() {
        lib->fns.clang_experimental_cas_CachedCompilation_dispose(cxComp);
    }
};

struct LibclangScanner {
    LibclangWrapper* lib;

    LibclangFunctions::CXDependencyScannerService service;

    /// The available pool of workers.
    std::list<std::unique_ptr<ScannerWorker>> workers;

    /// The lock to protect worker access.
    std::mutex workersLock;

    LibclangScanner(LibclangWrapper *lib,
                    LibclangFunctions::CXDependencyMode Mode,
                    LibclangCASDatabases *casDBs, LibclangCASOptions *casOpts)
        : lib(lib) {
        auto opts = lib->fns.clang_experimental_DependencyScannerServiceOptions_create();
        lib->fns.clang_experimental_DependencyScannerServiceOptions_setDependencyMode(opts, Mode);
        if (casDBs) {
            lib->fns.clang_experimental_DependencyScannerServiceOptions_setCASDatabases(opts, casDBs->casDBs);
        }
        if (casOpts) {
            lib->fns.clang_experimental_DependencyScannerServiceOptions_setCASOptions(opts, casOpts->casOpts);
        }
        if (lib->fns.clang_experimental_DependencyScannerServiceOptions_setCWDOptimization) {
            lib->fns.clang_experimental_DependencyScannerServiceOptions_setCWDOptimization(opts, 1);
        }
        service = lib->fns.clang_experimental_DependencyScannerService_create_v1(opts);
        assert(service && "unable to create service");
        lib->fns.clang_experimental_DependencyScannerServiceOptions_dispose(opts);
    }

    ~LibclangScanner() {
        lib->fns.clang_experimental_DependencyScannerService_dispose_v0(
            service);
    }

    /// Get a fresh worker.
    ///
    /// We use a round robin strategy to balance the worker use.
    auto getWorker() -> std::unique_ptr<ScannerWorker> {
        std::lock_guard<std::mutex> guard(workersLock);

        // If we have run out of workers, allocate a new one.
        if (workers.empty()) {
            return std::unique_ptr<ScannerWorker>(
                new ScannerWorker(lib, service));
        }

        // Otherwise, return from the back.
        auto result = std::move(workers.back());
        workers.pop_back();
        return result;
    }

    /// Add a worker back to the pool.
    auto releaseWorker(std::unique_ptr<ScannerWorker> &&worker) {
        std::lock_guard<std::mutex> guard(workersLock);

        workers.emplace_front(std::move(worker));
    }
};

}

template <typename CallTy> struct FunctionObjectCallback {
    void *Context;
    CallTy *Callback;
};

namespace detail {
template <typename FuncTy, typename CallTy>
struct functionObjectToCCallbackRefImpl;

template <typename FuncTy, typename Ret, typename... Args>
struct functionObjectToCCallbackRefImpl<FuncTy, Ret(Args...)> {
    static FunctionObjectCallback<Ret(void *, Args...)> impl(FuncTy &F) {
        auto Func = +[](void *C, Args... V) -> Ret {
            return (*reinterpret_cast<std::decay_t<FuncTy> *>(C))(
                std::forward<Args>(V)...);
        };

        return {&F, Func};
    }
};
} // namespace detail

/// Returns a function pointer and context pair suitable for use as a C
/// callback.
///
/// \param F the function object to turn into a C callback. The returned
///   callback has the same lifetime as F.
template <typename CallTy, typename FuncTy>
auto functionObjectToCCallbackRef(FuncTy &F) {
    return detail::functionObjectToCCallbackRefImpl<FuncTy, CallTy>::impl(F);
}

static clang_output_kind_t wrap(LibclangFunctions::CXOutputKind kind) {
    switch (kind) {
        case LibclangFunctions::CXOutputKind_ModuleFile:
            return clang_output_kind_moduleFile;
        case LibclangFunctions::CXOutputKind_Dependencies:
            return clang_output_kind_dependencies;
        case LibclangFunctions::CXOutputKind_DependenciesTarget:
            return clang_output_kind_dependenciesTarget;
        case LibclangFunctions::CXOutputKind_SerializedDiagnostics:
            return clang_output_kind_serializedDiagnostics;
    }
}

extern "C" {
    struct libclang_t_ {
        LibclangWrapper* wrapper;
    };
    struct libclang_scanner_t_ {
        LibclangScanner* scanner;
    };
    struct libclang_casoptions_t_ {
        LibclangCASOptions opts;
    };
    struct libclang_casdatabases_t_ {
        LibclangCASDatabases dbs;
    };
    struct libclang_cas_casobject_t_ {
        LibclangCASObject obj;
    };
    struct libclang_cas_cached_compilation_t_ {
        LibclangCASCachedCompilation cachedComp;
    };

    libclang_t libclang_open(const char* path) {
        auto wrapper = new LibclangWrapper{ path };
        if (!wrapper->handle) {
            delete wrapper;
            return nullptr;
        }
        return new libclang_t_{ wrapper };
    }

    void libclang_leak(libclang_t lib) {
        lib->wrapper->leak();
    }

    void libclang_close(libclang_t lib) {
        delete lib->wrapper;
        delete lib;
    }

    void libclang_get_clang_version(libclang_t lib,
                                    void (^callback)(const char*)) {
        // Validate that we support this clang version; for now we only support
        // clang-1100 or newer.
        auto v = lib->wrapper->fns.clang_getClangVersion();
        callback(lib->wrapper->fns.clang_getCString(v));
        lib->wrapper->fns.clang_disposeString(v);
    }

    bool libclang_has_required_api(libclang_t lib) {
        return lib->wrapper->hasRequiredAPI;
    }

    bool libclang_has_scanner(libclang_t lib) {
        return lib->wrapper->hasDependencyScanner;
    }

    bool libclang_has_structured_scanner_diagnostics(libclang_t lib) {
        return lib->wrapper->hasStructuredScanningDiagnostics;
    }

    libclang_scanner_t libclang_scanner_create(libclang_t lib, libclang_casdatabases_t casdbs, libclang_casoptions_t casOpts) {
        return new libclang_scanner_t_{new LibclangScanner(
            lib->wrapper, LibclangFunctions::CXDependencyMode_Full,
            casdbs ? &casdbs->dbs : nullptr, casOpts ? &casOpts->opts : nullptr)};
    }

    void libclang_scanner_dispose(libclang_scanner_t scanner) {
        delete scanner->scanner;
        delete scanner;
    }

    bool libclang_has_cas(libclang_t lib) {
        return lib->wrapper->hasCAS;
    }

    bool libclang_has_cas_plugin_feature(libclang_t lib) {
        return lib->wrapper->fns.clang_experimental_cas_Options_setPluginPath &&
               lib->wrapper->fns.clang_experimental_cas_Options_setPluginOption;
    }

    bool libclang_has_cas_pruning_feature(libclang_t lib) {
        return lib->wrapper->fns.clang_experimental_cas_Databases_set_size_limit &&
               lib->wrapper->fns.clang_experimental_cas_Databases_get_storage_size &&
               lib->wrapper->fns.clang_experimental_cas_Databases_prune_ondisk_data;
    }

    bool libclang_has_cas_up_to_date_checks_feature(libclang_t lib) {
        return lib->wrapper->fns.clang_experimental_DepGraphModule_getIncludeTreeID &&
               lib->wrapper->fns.clang_experimental_cas_isMaterialized;
    }

    bool libclang_has_current_working_directory_optimization(libclang_t lib) {
        return lib->wrapper->fns.clang_experimental_DepGraphModule_isCWDIgnored &&
               lib->wrapper->fns.clang_experimental_DependencyScannerServiceOptions_setCWDOptimization;
    }

    libclang_casoptions_t libclang_casoptions_create(libclang_t lib) {
        auto opts = lib->wrapper->fns.clang_experimental_cas_Options_create();
        return new libclang_casoptions_t_{{lib->wrapper, opts}};
    }

    void libclang_casoptions_dispose(libclang_casoptions_t opts) {
        delete opts;
    }

    void libclang_casoptions_setondiskpath(libclang_casoptions_t opts, const char *path) {
        opts->opts.setOnDiskPath(path);
    }

    void libclang_casoptions_setpluginpath(libclang_casoptions_t opts, const char *path) {
        opts->opts.setPluginPath(path);
    }

    void libclang_casoptions_setpluginoption(libclang_casoptions_t opts, const char *name, const char *value) {
        opts->opts.setPluginOption(name, value);
    }

    libclang_casdatabases_t libclang_casdatabases_create(libclang_casoptions_t opts, void (^error_callback)(const char *)) {
        LibclangWrapper* lib = opts->opts.lib;
        LibclangFunctions::CXString error;
        auto reportError = [&]() -> libclang_casdatabases_t {
            error_callback(lib->fns.clang_getCString(error));
            lib->fns.clang_disposeString(error);
            return nullptr;
        };

        auto casDBs = lib->fns.clang_experimental_cas_Databases_create(opts->opts.casOpts, &error);
        if (!casDBs)
            return reportError();
        return new libclang_casdatabases_t_{{lib, casDBs}};
    }

    void libclang_casdatabases_dispose(libclang_casdatabases_t casdbs) {
        delete casdbs;
    }

    int64_t libclang_casdatabases_get_ondisk_size(libclang_casdatabases_t casdbs, void (^error_callback)(const char *)) {
        auto lib = casdbs->dbs.lib;
        if (!lib->fns.clang_experimental_cas_Databases_get_storage_size)
            return -1;
        LibclangFunctions::CXError error = nullptr;
        int64_t ret = lib->fns.clang_experimental_cas_Databases_get_storage_size(casdbs->dbs.casDBs, &error);
        switch (ret) {
            case -1:
                assert(!error);
                return -1;
            case -2:
                if (error) {
                    error_callback(lib->fns.clang_Error_getDescription(error));
                    lib->fns.clang_Error_dispose(error);
                }
                return -2;
        default:
            return ret;
        }
    }

    bool libclang_casdatabases_set_ondisk_size_limit(libclang_casdatabases_t casdbs, int64_t size_limit, void (^error_callback)(const char *)) {
        auto lib = casdbs->dbs.lib;
        if (!lib->fns.clang_experimental_cas_Databases_set_size_limit)
            return false;
        if (LibclangFunctions::CXError error = lib->fns.clang_experimental_cas_Databases_set_size_limit(casdbs->dbs.casDBs, size_limit)) {
            error_callback(lib->fns.clang_Error_getDescription(error));
            lib->fns.clang_Error_dispose(error);
            return true;
        }
        return false;
    }

    bool libclang_casdatabases_prune_ondisk_data(libclang_casdatabases_t casdbs, void (^error_callback)(const char *)) {
        auto lib = casdbs->dbs.lib;
        if (!lib->fns.clang_experimental_cas_Databases_prune_ondisk_data)
            return false;
        if (LibclangFunctions::CXError error = lib->fns.clang_experimental_cas_Databases_prune_ondisk_data(casdbs->dbs.casDBs)) {
            error_callback(lib->fns.clang_Error_getDescription(error));
            lib->fns.clang_Error_dispose(error);
            return true;
        }
        return false;
    }

    static const char **copyStringSet(LibclangWrapper *lib,
                                      LibclangFunctions::CXStringSet *set) {
        const char **ret = new const char *[set->Count + 1];
        ret[set->Count] = nullptr;
        for (int i = 0; i < set->Count; ++i)
            ret[i] = lib->fns.clang_getCString(set->Strings[i]);
        return ret;
    }

    static const char **copyStringSet(LibclangFunctions::CXCStringArray set) {
        const char **ret = new const char *[set.Count + 1];
        ret[set.Count] = nullptr;
        memcpy(ret, set.Strings, set.Count * sizeof(const char *));
        return ret;
    }

    static char *strdup_safe(const char *s) {
        return s ? strdup(s) : NULL;
    }

    static void populate_range_info(LibclangWrapper *lib, libclang_source_range_t lc_range, LibclangFunctions::CXSourceRange range) {
        LibclangFunctions::CXFile fixItStartFile;
        unsigned int fixItStartLine;
        unsigned int fixItStartColumn;
        unsigned int fixItStartOffset;
        LibclangFunctions::CXFile fixItEndFile;
        unsigned int fixItEndLine;
        unsigned int fixItEndColumn;
        unsigned int fixItEndOffset;

        lib->fns.clang_getSpellingLocation(lib->fns.clang_getRangeStart(range), &fixItStartFile, &fixItStartLine, &fixItStartColumn,    &fixItStartOffset);
        lib->fns.clang_getSpellingLocation(lib->fns.clang_getRangeEnd(range), &fixItEndFile, &fixItEndLine, &fixItEndColumn,    &fixItEndOffset);

        lc_range->start_line = fixItStartLine;
        lc_range->start_column = fixItStartColumn;
        lc_range->start_offset = fixItStartOffset;
        lc_range->end_line = fixItEndLine;
        lc_range->end_column = fixItEndColumn;
        lc_range->end_offset = fixItEndOffset;

        auto file = lib->fns.clang_getFileName(fixItStartFile);
        lc_range->path = strdup_safe(lib->fns.clang_getCString(file));
        lib->fns.clang_disposeString(file);
    }

    static void populate_diagnostic_info(LibclangWrapper *lib, libclang_diagnostic_t lc_diagnostic, LibclangFunctions::CXDiagnostic     diagnostic, unsigned int child_count) {
        LibclangFunctions::CXFile file;
        unsigned int line;
        unsigned int column;
        unsigned int offset;
        lib->fns.clang_getSpellingLocation(lib->fns.clang_getDiagnosticLocation(diagnostic), &file, &line, &column, &offset);
        if (file) {
            LibclangFunctions::CXString fileName = lib->fns.clang_getFileName(file);
            lc_diagnostic->file_name = strdup_safe(lib->fns.clang_getCString(fileName));
            lib->fns.clang_disposeString(fileName);
            lc_diagnostic->line = line;
            lc_diagnostic->column = column;
            lc_diagnostic->offset = offset;
        } else {
            lc_diagnostic->file_name = NULL;
            lc_diagnostic->line = 0;
            lc_diagnostic->column = 0;
            lc_diagnostic->offset = 0;
        }

        unsigned int range_count = lib->fns.clang_getDiagnosticNumRanges(diagnostic);
        lc_diagnostic->range_count = range_count;
        lc_diagnostic->ranges = range_count ? new libclang_source_range_t[range_count] : NULL;

        for (unsigned int i = 0; i < range_count; ++i) {
            lc_diagnostic->ranges[i] = new libclang_source_range_t_();
            populate_range_info(lib, lc_diagnostic->ranges[i], lib->fns.clang_getDiagnosticRange(diagnostic, i));
        }

        lc_diagnostic->severity = lib->fns.clang_getDiagnosticSeverity(diagnostic);

        LibclangFunctions::CXString spelling = lib->fns.clang_getDiagnosticSpelling(diagnostic);
        lc_diagnostic->text = strdup(lib->fns.clang_getCString(spelling));
        lib->fns.clang_disposeString(spelling);

        LibclangFunctions::CXString optionFlag = lib->fns.clang_getDiagnosticOption(diagnostic, NULL);
        const char * optionCStr = lib->fns.clang_getCString(optionFlag);
        if (optionCStr && *optionCStr) {
            if (strncmp(optionCStr, "-W", 2) == 0) {
                // get rid of the "-W" that libclang unconditionally prepends to the value from the diagnostics file
                optionCStr += 2;
            }
            lc_diagnostic->option_name = strdup_safe(optionCStr);
        }
        else {
            lc_diagnostic->option_name = NULL;
        }
        lib->fns.clang_disposeString(optionFlag);

        if (lib->fns.clang_getDiagnosticCategory(diagnostic)) {
            LibclangFunctions::CXString categoryText = lib->fns.clang_getDiagnosticCategoryText(diagnostic);
            lc_diagnostic->category_text = strdup_safe(lib->fns.clang_getCString(categoryText));
            lib->fns.clang_disposeString(categoryText);
        } else {
            lc_diagnostic->category_text = NULL;
        }

        const unsigned int fixit_count = lib->fns.clang_getDiagnosticNumFixIts(diagnostic);
        lc_diagnostic->fixit_count = fixit_count;
        lc_diagnostic->fixits = fixit_count ? new libclang_diagnostic_fixit_t[fixit_count] : NULL;

        for (unsigned int i = 0; i < fixit_count; ++i) {
            lc_diagnostic->fixits[i] = new libclang_diagnostic_fixit_t_();

            LibclangFunctions::CXSourceRange cxReplacementRange;
            auto fixit = lib->fns.clang_getDiagnosticFixIt(diagnostic, i, &cxReplacementRange);

            lc_diagnostic->fixits[i]->text = strdup(lib->fns.clang_getCString(fixit));

            lib->fns.clang_disposeString(fixit);

            lc_diagnostic->fixits[i]->range = new libclang_source_range_t_();
            populate_range_info(lib, lc_diagnostic->fixits[i]->range, cxReplacementRange);
        }

        lc_diagnostic->child_count = child_count;
        lc_diagnostic->child_diagnostics = child_count ? new libclang_diagnostic_t[child_count] : NULL;
    }

    static libclang_diagnostic_set_t libclang_diagnostic_set_create(LibclangWrapper *lib, LibclangFunctions::CXDiagnosticSet    diagnostics) {
        const unsigned int count = lib->fns.clang_getNumDiagnosticsInSet(diagnostics);

        libclang_diagnostic_set_t diagnostic_set = new libclang_diagnostic_set_t_();
        diagnostic_set->count = count;
        diagnostic_set->diagnostics = new libclang_diagnostic_t[count];

        for (unsigned int i = 0; i < count; ++i) {
            LibclangFunctions::CXDiagnostic diagnostic = lib->fns.clang_getDiagnosticInSet(diagnostics, i);

            // This CXDiagnosticSet does not need to be released by clang_disposeDiagnosticSet.
            LibclangFunctions::CXDiagnosticSet childDiagnostics = lib->fns.clang_getChildDiagnostics(diagnostic);
            const unsigned int childCount = lib->fns.clang_getNumDiagnosticsInSet(childDiagnostics);

            diagnostic_set->diagnostics[i] = new libclang_diagnostic_t_();
            populate_diagnostic_info(lib, diagnostic_set->diagnostics[i], diagnostic, childCount);

            for (unsigned int j = 0; j < childCount; ++j) {
                LibclangFunctions::CXDiagnostic childDiagnostic = lib->fns.clang_getDiagnosticInSet(childDiagnostics, j);

                diagnostic_set->diagnostics[i]->child_diagnostics[j] = new libclang_diagnostic_t_();
                populate_diagnostic_info(lib, diagnostic_set->diagnostics[i]->child_diagnostics[j], childDiagnostic, 0);

                lib->fns.clang_disposeDiagnostic(childDiagnostic);
            }

            lib->fns.clang_disposeDiagnostic(diagnostic);
        }

        lib->fns.clang_disposeDiagnosticSet(diagnostics);

        return diagnostic_set;
    }

    bool libclang_scanner_scan_dependencies(
        libclang_scanner_t scanner, int argc, char *const *argv, const char *workingDirectory,
        __attribute__((noescape)) module_lookup_output_t module_lookup_output,
        __attribute__((noescape)) void (^modules_callback)(clang_module_dependency_set_t, bool),
        void (^callback)(clang_file_dependencies_t),
        void (^diagnostics_callback)(const libclang_diagnostic_set_t),
        void (^error_callback)(const char *)) {
        // Get a worker.
        auto lib = scanner->scanner->lib;
        auto worker{scanner->scanner->getWorker()};

        // Scan for dependencies.
        LibclangFunctions::CXString error;
        bool providedErrorToCaller = false;

        auto lookupOutput = [&](const char *moduleName, const char *contextHash,
                                LibclangFunctions::CXOutputKind kind, char *output, size_t maxLen) {
            return module_lookup_output(moduleName, contextHash, wrap(kind), output, maxLen);
        };

        auto lookupOutputCB = functionObjectToCCallbackRef<
            size_t(const char *ModuleName, const char *ContextHash, LibclangFunctions::CXOutputKind Kind,
                   char *Output, size_t MaxLen)>(lookupOutput);

        LibclangFunctions::CXDepGraph depGraph = nullptr;

        auto scanSettings = lib->fns.clang_experimental_DependencyScannerWorkerScanSettings_create(
          argc, argv, nullptr, workingDirectory, lookupOutputCB.Context, lookupOutputCB.Callback);
        auto result = lib->fns.clang_experimental_DependencyScannerWorker_getDepGraph(
            worker.get()->worker, scanSettings, &depGraph);
        lib->fns.clang_experimental_DependencyScannerWorkerScanSettings_dispose(scanSettings);
        assert(result != LibclangFunctions::CXError_InvalidArguments &&
               "invalid arguments to clang_experimental_DependencyScannerWorker_getDepGraph");
        assert(depGraph || result != LibclangFunctions::CXError_Success);
        if (result != LibclangFunctions::CXError_Success) {
            std::string errorOutput;
            // depGraph shouldn't be null but checking to be safe.
            if (depGraph) {
                auto diags = libclang_diagnostic_set_create(lib, lib->fns.clang_experimental_DepGraph_getDiagnostics(depGraph));
                diagnostics_callback(diags);
                libclang_diagnostic_set_dispose(diags);
                lib->fns.clang_experimental_DepGraph_dispose(depGraph);
                depGraph = nullptr;
            }
            error_callback(errorOutput.c_str());
            providedErrorToCaller = true;
        }

        if (depGraph) {
            std::vector<LibclangFunctions::CXDepGraphModule> modsToDispose;
            size_t num_mods = lib->fns.clang_experimental_DepGraph_getNumModules(depGraph);
            clang_module_dependency_t *modules = new clang_module_dependency_t[num_mods];
            for (size_t i = 0; i < num_mods; ++i) {
                auto depMod = lib->fns.clang_experimental_DepGraph_getModuleTopological
                    ? lib->fns.clang_experimental_DepGraph_getModuleTopological(depGraph, i)
                    : lib->fns.clang_experimental_DepGraph_getModule(depGraph, i);
                const char *name = lib->fns.clang_experimental_DepGraphModule_getName(depMod);
                const char *contextHash = lib->fns.clang_experimental_DepGraphModule_getContextHash(depMod);
                const char *moduleMapPath = lib->fns.clang_experimental_DepGraphModule_getModuleMapPath(depMod);
                const char *cacheKey = lib->fns.clang_experimental_DepGraphModule_getCacheKey
                    ? lib->fns.clang_experimental_DepGraphModule_getCacheKey(depMod)
                    : nullptr;
                const char *includeTreeID = lib->fns.clang_experimental_DepGraphModule_getIncludeTreeID
                    ? lib->fns.clang_experimental_DepGraphModule_getIncludeTreeID(depMod)
                    : nullptr;
                bool isCWDIgnored = lib->fns.clang_experimental_DepGraphModule_isCWDIgnored ? lib->fns.clang_experimental_DepGraphModule_isCWDIgnored(depMod) : 0;
                LibclangFunctions::CXCStringArray fileDeps = lib->fns.clang_experimental_DepGraphModule_getFileDeps(depMod);
                LibclangFunctions::CXCStringArray moduleDeps = lib->fns.clang_experimental_DepGraphModule_getModuleDeps(depMod);
                LibclangFunctions::CXCStringArray buildArguments = lib->fns.clang_experimental_DepGraphModule_getBuildArguments(depMod);

                modules[i].name = name;
                modules[i].context_hash = contextHash;
                modules[i].module_map_path = moduleMapPath;
                modules[i].include_tree_id = includeTreeID;
                modules[i].is_cwd_ignored = isCWDIgnored;
                modules[i].cache_key = cacheKey;
                modules[i].file_deps = copyStringSet(fileDeps);
                modules[i].module_deps = copyStringSet(moduleDeps);
                modules[i].build_arguments = copyStringSet(buildArguments);

                modsToDispose.push_back(depMod);
            }
            clang_module_dependency_set_t ms{(int)num_mods, modules};
            modules_callback(ms, lib->fns.clang_experimental_DepGraph_getModuleTopological != nullptr);
            for (int i = 0; i < num_mods; ++i) {
                delete[] modules[i].file_deps;
                delete[] modules[i].module_deps;
                delete[] modules[i].build_arguments;
            }
            delete[] modules;
            for (const auto &mod : modsToDispose)
                lib->fns.clang_experimental_DepGraphModule_dispose(mod);
            modsToDispose.clear();

            std::vector<LibclangFunctions::CXDepGraphTUCommand> tuCmdsToDispose;
            const char *tuContextHash = lib->fns.clang_experimental_DepGraph_getTUContextHash(depGraph);
            LibclangFunctions::CXCStringArray tuFileDeps = lib->fns.clang_experimental_DepGraph_getTUFileDeps(depGraph);
            LibclangFunctions::CXCStringArray tuModuleDeps = lib->fns.clang_experimental_DepGraph_getTUModuleDeps(depGraph);
            const char *includeTreeID = lib->fns.clang_experimental_DepGraph_getTUIncludeTreeID
                ? lib->fns.clang_experimental_DepGraph_getTUIncludeTreeID(depGraph)
                : nullptr;
            size_t num_cmds = lib->fns.clang_experimental_DepGraph_getNumTUCommands(depGraph);
            auto *commands = new clang_translation_unit_command_t[num_cmds];
            for (size_t i = 0; i < num_cmds; ++i) {
                auto tuCmd = lib->fns.clang_experimental_DepGraph_getTUCommand(depGraph, i);
                const char *cacheKey = lib->fns.clang_experimental_DepGraphTUCommand_getCacheKey
                    ? lib->fns.clang_experimental_DepGraphTUCommand_getCacheKey(tuCmd)
                    : nullptr;
                const char *executable = lib->fns.clang_experimental_DepGraphTUCommand_getExecutable(tuCmd);
                LibclangFunctions::CXCStringArray buildArguments = lib->fns.clang_experimental_DepGraphTUCommand_getBuildArguments(tuCmd);

                commands[i].context_hash = tuContextHash;
                commands[i].file_deps = copyStringSet(tuFileDeps);
                commands[i].module_deps = copyStringSet(tuModuleDeps);
                commands[i].cache_key = cacheKey;
                commands[i].executable = executable;
                commands[i].build_arguments = copyStringSet(buildArguments);

                tuCmdsToDispose.push_back(tuCmd);
            }
            callback({includeTreeID, num_cmds, commands});
            for (size_t i = 0; i < num_cmds; ++i) {
                delete[] commands[i].file_deps;
                delete[] commands[i].module_deps;
                delete[] commands[i].build_arguments;
            }
            delete[] commands;
            for (const auto &cmd : tuCmdsToDispose)
                lib->fns.clang_experimental_DepGraphTUCommand_dispose(cmd);
            lib->fns.clang_experimental_DepGraph_dispose(depGraph);
        } else if (!providedErrorToCaller) {
            error_callback(lib->fns.clang_getCString(error));
            lib->fns.clang_disposeString(error);
        }

        // Return the worker to the pool.
        scanner->scanner->releaseWorker(std::move(worker));

        return depGraph != nullptr;
    }

    bool libclang_driver_get_actions(libclang_t wrapped_lib,
                                     int argc,
                                     char* const* argv,
                                     char* const* envp,
                                     const char* working_directory,
                                     void (^callback)(int argc,
                                                      const char** argv),
                                     void (^error_callback)(const char*)) {
        auto lib = wrapped_lib->wrapper;

        // Check if this libclang supports the driver API.
        if (!lib->fns.clang_Driver_getExternalActionsForCommand_v0 ||
            !lib->fns.clang_Driver_ExternalActionList_dispose) {
            // FIXME: We will need to extend to allow detecting error versus
            // missing support.
            error_callback("driver API unsupported");
            return false;
        }

        LibclangFunctions::CXDiagnosticSet diags;
        auto* actionList = lib->fns.clang_Driver_getExternalActionsForCommand_v0(
            argc, const_cast<const char**>(argv), const_cast<const char**>(envp),
            working_directory, &diags);
        if (!actionList) {
            if (diags) {
                const unsigned diagCount = lib->fns.clang_getNumDiagnosticsInSet(diags);
                unsigned dispOptions = lib->fns.clang_defaultDiagnosticDisplayOptions();
                for (unsigned i = 0; i < diagCount; i++) {
                    auto diag = lib->fns.clang_getDiagnosticInSet(diags, i);
                    auto error = lib->fns.clang_formatDiagnostic(diag, dispOptions);
                    error_callback(lib->fns.clang_getCString(error));
                    lib->fns.clang_disposeString(error);
                    lib->fns.clang_disposeDiagnostic(diag);
                }
                lib->fns.clang_disposeDiagnosticSet(diags);
            }

            error_callback("clang driver API failed to expand actions");
            return false;
        }

        for (int i = 0; i < actionList->Count; ++i) {
            callback(actionList->Actions[i]->ArgC, actionList->Actions[i]->ArgV);
        }

        lib->fns.clang_Driver_ExternalActionList_dispose(actionList);

        return true;
    }

    libclang_diagnostic_set_t libclang_read_diagnostics(libclang_t wrapped_lib,
                                                        const char *path,
                                                        const char** error_string) {
        auto lib = wrapped_lib->wrapper;

        LibclangFunctions::CXString errorString;
        LibclangFunctions::CXDiagnosticSet diagnostics = lib->fns.clang_loadDiagnostics(path, NULL, &errorString);
        if (!diagnostics) {
            if (error_string) {
                *error_string = strdup(lib->fns.clang_getCString(errorString));
            }
            lib->fns.clang_disposeString(errorString);
            return NULL;
        }

        return libclang_diagnostic_set_create(lib, diagnostics);
    }

    static void libclang_source_range_dispose(libclang_source_range_t range) {
        free(range->path);
        delete range;
    }

    static void libclang_diagnostic_fixit_dispose(libclang_diagnostic_fixit_t fixit) {
        free(fixit->text);
        libclang_source_range_dispose(fixit->range);
        delete fixit;
    }

    static void libclang_diagnostic_dispose(libclang_diagnostic_t diagnostic) {
        free(diagnostic->file_name);
        free(diagnostic->text);
        free(diagnostic->option_name);
        free(diagnostic->category_text);
        for (unsigned int i = 0; i < diagnostic->range_count; ++i) {
            libclang_source_range_dispose(diagnostic->ranges[i]);
        }
        delete[] diagnostic->ranges;
        for (unsigned int i = 0; i < diagnostic->fixit_count; ++i) {
            libclang_diagnostic_fixit_dispose(diagnostic->fixits[i]);
        }
        delete[] diagnostic->fixits;
        for (unsigned int i = 0; i < diagnostic->child_count; ++i) {
            libclang_diagnostic_dispose(diagnostic->child_diagnostics[i]);
        }
        delete[] diagnostic->child_diagnostics;
        delete diagnostic;
    }

    void libclang_diagnostic_set_dispose(libclang_diagnostic_set_t diagnostic_set) {
        for (unsigned int i = 0; i < diagnostic_set->count; ++i) {
            libclang_diagnostic_dispose(diagnostic_set->diagnostics[i]);
        }
        delete[] diagnostic_set->diagnostics;
        delete diagnostic_set;
    }

    void libclang_cas_load_object_async(libclang_casdatabases_t casdbs, const char *casid, void (^callback)(libclang_cas_casobject_t, const char *error)) {
        auto lib = casdbs->dbs.lib;
        struct CallCtx {
            LibclangWrapper* lib;
            void (^callback)(libclang_cas_casobject_t, const char *error);

            CallCtx(LibclangWrapper* lib, void (^callback)(libclang_cas_casobject_t, const char *error))
            : lib(lib), callback(Block_copy(callback)) {}

            ~CallCtx() {
                Block_release(callback);
            }
        };
        auto ctx = new CallCtx{lib, std::move(callback)};
        lib->fns.clang_experimental_cas_loadObjectByString_async(casdbs->dbs.casDBs, casid, ctx, [](void *ctx, LibclangFunctions::CXCASObject obj, LibclangFunctions::CXError error) {
            std::unique_ptr<CallCtx> callCtx(static_cast<CallCtx *>(ctx));
            auto lib = callCtx->lib;
            if (!obj) {
                if (error) {
                    callCtx->callback(nullptr, lib->fns.clang_Error_getDescription(error));
                    lib->fns.clang_Error_dispose(error);
                } else {
                    callCtx->callback(nullptr, /*error=*/nullptr);
                }
            } else {
                assert(!error);
                callCtx->callback(new libclang_cas_casobject_t_{{lib, obj}}, /*error=*/nullptr);
            }
        }, nullptr);
    }

    void libclang_cas_casobject_dispose(libclang_cas_casobject_t obj) {
        delete obj;
    }

    libclang_cas_cached_compilation_t libclang_cas_get_cached_compilation(libclang_casdatabases_t casdbs, const char *cache_key, bool globally, void (^error_callback)(const char *)) {
        auto lib = casdbs->dbs.lib;
        LibclangFunctions::CXError error = nullptr;
        auto cachedComp = lib->fns.clang_experimental_cas_getCachedCompilation(casdbs->dbs.casDBs, cache_key, globally, &error);
        if (!cachedComp) {
            if (error) {
                error_callback(lib->fns.clang_Error_getDescription(error));
                lib->fns.clang_Error_dispose(error);
            }
            return nullptr;
        }
        assert(!error);
        return new libclang_cas_cached_compilation_t_{{lib, cachedComp}};
    }

    void libclang_cas_get_cached_compilation_async(libclang_casdatabases_t casdbs, const char *cache_key, bool globally, void (^callback)(libclang_cas_cached_compilation_t, const char *error)) {
        auto lib = casdbs->dbs.lib;
        struct CallCtx {
            LibclangWrapper* lib;
            void (^callback)(libclang_cas_cached_compilation_t, const char *error);

            CallCtx(LibclangWrapper* lib, void (^callback)(libclang_cas_cached_compilation_t, const char *error))
            : lib(lib), callback(Block_copy(callback)) {}

            ~CallCtx() {
                Block_release(callback);
            }
        };
        auto ctx = new CallCtx{lib, std::move(callback)};
        lib->fns.clang_experimental_cas_getCachedCompilation_async(casdbs->dbs.casDBs, cache_key, globally, ctx, [](void *ctx, LibclangFunctions::CXCASCachedCompilation cxCachedComp, LibclangFunctions::CXError error) {
            std::unique_ptr<CallCtx> callCtx(static_cast<CallCtx *>(ctx));
            auto lib = callCtx->lib;
            if (!cxCachedComp) {
                if (error) {
                    callCtx->callback(nullptr, lib->fns.clang_Error_getDescription(error));
                    lib->fns.clang_Error_dispose(error);
                } else {
                    callCtx->callback(nullptr, /*error=*/nullptr);
                }
            } else {
                assert(!error);
                callCtx->callback(new libclang_cas_cached_compilation_t_{{lib, cxCachedComp}}, /*error=*/nullptr);
            }
        }, nullptr);
    }

    void libclang_cas_cached_compilation_dispose(libclang_cas_cached_compilation_t comp) {
        delete comp;
    }

    size_t libclang_cas_cached_compilation_get_num_outputs(libclang_cas_cached_compilation_t comp) {
        auto lib = comp->cachedComp.lib;
        return lib->fns.clang_experimental_cas_CachedCompilation_getNumOutputs(comp->cachedComp.cxComp);
    }

    void libclang_cas_cached_compilation_get_output_name(libclang_cas_cached_compilation_t comp, size_t output_idx, void (^callback)(const char*)) {
        auto lib = comp->cachedComp.lib;
        LibclangFunctions::CXString name = lib->fns.clang_experimental_cas_CachedCompilation_getOutputName(comp->cachedComp.cxComp, output_idx);
        callback(lib->fns.clang_getCString(name));
        lib->fns.clang_disposeString(name);
    }

    void libclang_cas_cached_compilation_get_output_casid(libclang_cas_cached_compilation_t comp, size_t output_idx, void (^callback)(const char*)) {
        auto lib = comp->cachedComp.lib;
        LibclangFunctions::CXString casid = lib->fns.clang_experimental_cas_CachedCompilation_getOutputCASIDString(comp->cachedComp.cxComp, output_idx);
        callback(lib->fns.clang_getCString(casid));
        lib->fns.clang_disposeString(casid);
    }

    bool libclang_cas_casobject_is_materialized(libclang_casdatabases_t casdbs, const char *casid, void (^error_callback)(const char *)) {
        auto lib = casdbs->dbs.lib;
        LibclangFunctions::CXError OutError;
        if (!lib->fns.clang_experimental_cas_isMaterialized) {
            return true;
        }
        bool is_materialized = lib->fns.clang_experimental_cas_isMaterialized(casdbs->dbs.casDBs, casid, &OutError);
        if (OutError) {
            error_callback(lib->fns.clang_Error_getDescription(OutError));
            lib->fns.clang_Error_dispose(OutError);
            return false;
        }
        return is_materialized;
    }

    bool libclang_cas_cached_compilation_is_output_materialized(libclang_cas_cached_compilation_t comp, size_t output_idx) {
        auto lib = comp->cachedComp.lib;
        return lib->fns.clang_experimental_cas_CachedCompilation_isOutputMaterialized(comp->cachedComp.cxComp, output_idx);
    }

    void libclang_cas_cached_compilation_make_global_async(libclang_cas_cached_compilation_t comp, void (^callback)(const char *error)) {
        auto lib = comp->cachedComp.lib;
        struct CallCtx {
            LibclangWrapper* lib;
            void (^callback)(const char *error);

            CallCtx(LibclangWrapper* lib, void (^callback)(const char *error))
            : lib(lib), callback(Block_copy(callback)) {}

            ~CallCtx() {
                Block_release(callback);
            }
        };
        auto ctx = new CallCtx{lib, std::move(callback)};
        lib->fns.clang_experimental_cas_CachedCompilation_makeGlobal(comp->cachedComp.cxComp, ctx, [](void *ctx, LibclangFunctions::CXError error) {
            std::unique_ptr<CallCtx> callCtx(static_cast<CallCtx *>(ctx));
            auto lib = callCtx->lib;
            if (error) {
                callCtx->callback(lib->fns.clang_Error_getDescription(error));
                lib->fns.clang_Error_dispose(error);
            } else {
                callCtx->callback(nullptr);
            }
        }, nullptr);
    }

    /// \returns True on success, false on failure.
    bool libclang_cas_replay_compilation(libclang_cas_cached_compilation_t comp, int argc, char *const *argv, const char *workingDirectory, void (^callback)(const char* diagnostic_text, const char *error)) {
        auto lib = comp->cachedComp.lib;
        LibclangFunctions::CXError error = nullptr;
        auto cxReplayRes = lib->fns.clang_experimental_cas_replayCompilation(comp->cachedComp.cxComp, argc, argv, workingDirectory, /*reserved*/nullptr, &error);
        if (!cxReplayRes) {
            if (error) {
                callback(nullptr, lib->fns.clang_Error_getDescription(error));
                lib->fns.clang_Error_dispose(error);
            } else {
                callback(nullptr, "cas replay failed without returning error");
            }
            return false;
        }
        assert(!error);
        LibclangFunctions::CXString diagText = lib->fns.clang_experimental_cas_ReplayResult_getStderr(cxReplayRes);
        callback(lib->fns.clang_getCString(diagText), nullptr);
        lib->fns.clang_disposeString(diagText);
        lib->fns.clang_experimental_cas_ReplayResult_dispose(cxReplayRes);
        return true;
    }

}
