#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2025 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See http://swift.org/LICENSE.txt for license information
## See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

set -euo pipefail

fail=0

while IFS= read -r file; do
  # Skip empty or binary files
  if [ ! -s "$file" ] || [[ "$file" == *png ]] || [[ "$file" == *mlmodel ]] || [[ "$file" == *mlpackage* ]] ; then
    continue
  fi

  # --- Check for trailing whitespace (spaces or tabs before end of line) ---
  # Using POSIX-compatible regex; no -P flag needed.
  if grep -nE '[[:space:]]+$' "$file" >/dev/null; then
    echo "❌ Trailing whitespace in: $file"
    # Print offending lines (indent for readability)
    grep -nE '[[:space:]]+$' "$file" | sed 's/^/    /'
    fail=1
  fi

  # --- Check for final newline ---
  # tail -c handles both GNU and BSD variants
  lastchar=$(tail -c 1 "$file" | od -An -tx1 | tr -d ' \n')
  if [[ "$lastchar" != "0a" ]]; then
    echo "❌ Missing final newline: $file"
    fail=1
  fi

done < <(git ls-files)

if [[ $fail -eq 0 ]]; then
  echo "✅ All tracked files are clean (no trailing whitespace, final newline present)."
else
  echo "⚠️  Some files failed checks."
  exit 1
fi
