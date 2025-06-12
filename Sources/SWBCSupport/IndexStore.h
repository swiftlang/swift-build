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

#ifndef INDEXSTORE_H
#define INDEXSTORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

typedef void *indexstore_error_t;

typedef struct {
  const char *data;
  size_t length;
} indexstore_string_ref_t;

typedef void *indexstore_t;
typedef void *indexstore_symbol_t;

typedef enum {
  INDEXSTORE_SYMBOL_KIND_UNKNOWN = 0,
  INDEXSTORE_SYMBOL_KIND_MODULE = 1,
  INDEXSTORE_SYMBOL_KIND_NAMESPACE = 2,
  INDEXSTORE_SYMBOL_KIND_NAMESPACEALIAS = 3,
  INDEXSTORE_SYMBOL_KIND_MACRO = 4,
  INDEXSTORE_SYMBOL_KIND_ENUM = 5,
  INDEXSTORE_SYMBOL_KIND_STRUCT = 6,
  INDEXSTORE_SYMBOL_KIND_CLASS = 7,
  INDEXSTORE_SYMBOL_KIND_PROTOCOL = 8,
  INDEXSTORE_SYMBOL_KIND_EXTENSION = 9,
  INDEXSTORE_SYMBOL_KIND_UNION = 10,
  INDEXSTORE_SYMBOL_KIND_TYPEALIAS = 11,
  INDEXSTORE_SYMBOL_KIND_FUNCTION = 12,
  INDEXSTORE_SYMBOL_KIND_VARIABLE = 13,
  INDEXSTORE_SYMBOL_KIND_FIELD = 14,
  INDEXSTORE_SYMBOL_KIND_ENUMCONSTANT = 15,
  INDEXSTORE_SYMBOL_KIND_INSTANCEMETHOD = 16,
  INDEXSTORE_SYMBOL_KIND_CLASSMETHOD = 17,
  INDEXSTORE_SYMBOL_KIND_STATICMETHOD = 18,
  INDEXSTORE_SYMBOL_KIND_INSTANCEPROPERTY = 19,
  INDEXSTORE_SYMBOL_KIND_CLASSPROPERTY = 20,
  INDEXSTORE_SYMBOL_KIND_STATICPROPERTY = 21,
  INDEXSTORE_SYMBOL_KIND_CONSTRUCTOR = 22,
  INDEXSTORE_SYMBOL_KIND_DESTRUCTOR = 23,
  INDEXSTORE_SYMBOL_KIND_CONVERSIONFUNCTION = 24,
  INDEXSTORE_SYMBOL_KIND_PARAMETER = 25,
  INDEXSTORE_SYMBOL_KIND_USING = 26,

  INDEXSTORE_SYMBOL_KIND_COMMENTTAG = 1000,
} indexstore_symbol_kind_t;

typedef enum {
  INDEXSTORE_SYMBOL_PROPERTY_GENERIC                          = 1 << 0,
  INDEXSTORE_SYMBOL_PROPERTY_TEMPLATE_PARTIAL_SPECIALIZATION  = 1 << 1,
  INDEXSTORE_SYMBOL_PROPERTY_TEMPLATE_SPECIALIZATION          = 1 << 2,
  INDEXSTORE_SYMBOL_PROPERTY_UNITTEST                         = 1 << 3,
  INDEXSTORE_SYMBOL_PROPERTY_IBANNOTATED                      = 1 << 4,
  INDEXSTORE_SYMBOL_PROPERTY_IBOUTLETCOLLECTION               = 1 << 5,
  INDEXSTORE_SYMBOL_PROPERTY_GKINSPECTABLE                    = 1 << 6,
  INDEXSTORE_SYMBOL_PROPERTY_LOCAL                            = 1 << 7,
  INDEXSTORE_SYMBOL_PROPERTY_PROTOCOL_INTERFACE               = 1 << 8,
  INDEXSTORE_SYMBOL_PROPERTY_SWIFT_ASYNC                      = 1 << 16,
} indexstore_symbol_property_t;

typedef enum {
  INDEXSTORE_SYMBOL_ROLE_DECLARATION  = 1 << 0,
  INDEXSTORE_SYMBOL_ROLE_DEFINITION   = 1 << 1,
  INDEXSTORE_SYMBOL_ROLE_REFERENCE    = 1 << 2,
  INDEXSTORE_SYMBOL_ROLE_READ         = 1 << 3,
  INDEXSTORE_SYMBOL_ROLE_WRITE        = 1 << 4,
  INDEXSTORE_SYMBOL_ROLE_CALL         = 1 << 5,
  INDEXSTORE_SYMBOL_ROLE_DYNAMIC      = 1 << 6,
  INDEXSTORE_SYMBOL_ROLE_ADDRESSOF    = 1 << 7,
  INDEXSTORE_SYMBOL_ROLE_IMPLICIT     = 1 << 8,
  INDEXSTORE_SYMBOL_ROLE_UNDEFINITION = 1 << 19,

  // Relation roles.
  INDEXSTORE_SYMBOL_ROLE_REL_CHILDOF     = 1 << 9,
  INDEXSTORE_SYMBOL_ROLE_REL_BASEOF      = 1 << 10,
  INDEXSTORE_SYMBOL_ROLE_REL_OVERRIDEOF  = 1 << 11,
  INDEXSTORE_SYMBOL_ROLE_REL_RECEIVEDBY  = 1 << 12,
  INDEXSTORE_SYMBOL_ROLE_REL_CALLEDBY    = 1 << 13,
  INDEXSTORE_SYMBOL_ROLE_REL_EXTENDEDBY  = 1 << 14,
  INDEXSTORE_SYMBOL_ROLE_REL_ACCESSOROF  = 1 << 15,
  INDEXSTORE_SYMBOL_ROLE_REL_CONTAINEDBY = 1 << 16,
  INDEXSTORE_SYMBOL_ROLE_REL_IBTYPEOF    = 1 << 17,
  INDEXSTORE_SYMBOL_ROLE_REL_SPECIALIZATIONOF = 1 << 18,
} indexstore_symbol_role_t;

typedef void *indexstore_unit_dependency_t;

typedef enum {
  INDEXSTORE_UNIT_DEPENDENCY_UNIT = 1,
  INDEXSTORE_UNIT_DEPENDENCY_RECORD = 2,
  INDEXSTORE_UNIT_DEPENDENCY_FILE = 3,
} indexstore_unit_dependency_kind_t;

typedef void *indexstore_symbol_relation_t;
typedef void *indexstore_occurrence_t;
typedef void *indexstore_record_reader_t;
typedef void *indexstore_unit_reader_t;

typedef struct {
  const char *
  (*error_get_description)(indexstore_error_t);

  void
  (*error_dispose)(indexstore_error_t);

  indexstore_t
  (*store_create)(const char *store_path, indexstore_error_t *error);

  void
  (*store_dispose)(indexstore_t);

  size_t
    (*store_get_unit_name_from_output_path)(indexstore_t store,
                                                    const char *output_path,
                                                    char *name_buf,
                                                    size_t buf_size);

  indexstore_symbol_kind_t
  (*symbol_get_kind)(indexstore_symbol_t);

  uint64_t
  (*symbol_get_properties)(indexstore_symbol_t);

  indexstore_string_ref_t
  (*symbol_get_name)(indexstore_symbol_t);

  uint64_t
  (*symbol_relation_get_roles)(indexstore_symbol_relation_t);

  indexstore_symbol_t
  (*symbol_relation_get_symbol)(indexstore_symbol_relation_t);

  indexstore_symbol_t
  (*occurrence_get_symbol)(indexstore_occurrence_t);

  bool
  (*occurrence_relations_apply_f)(indexstore_occurrence_t,
                                          void *context,
          bool(*applier)(void *context, indexstore_symbol_relation_t symbol_rel));

  indexstore_record_reader_t
  (*record_reader_create)(indexstore_t store, const char *record_name,
                                  indexstore_error_t *error);

  void
  (*record_reader_dispose)(indexstore_record_reader_t);

  bool
  (*record_reader_occurrences_apply_f)(indexstore_record_reader_t,
                                               void *context,
                    bool(*applier)(void *context, indexstore_occurrence_t occur));

  indexstore_unit_reader_t
  (*unit_reader_create)(indexstore_t store, const char *unit_name,
                                indexstore_error_t *error);

  void
  (*unit_reader_dispose)(indexstore_unit_reader_t);

  indexstore_string_ref_t
  (*unit_reader_get_module_name)(indexstore_unit_reader_t);

  indexstore_unit_dependency_kind_t
  (*unit_dependency_get_kind)(indexstore_unit_dependency_t);

  indexstore_string_ref_t
  (*unit_dependency_get_name)(indexstore_unit_dependency_t);

  bool
  (*unit_reader_dependencies_apply_f)(indexstore_unit_reader_t,
                                              void *context,
                      bool(*applier)(void *context, indexstore_unit_dependency_t));
} swiftbuild_indexstore_functions_t;

#endif
