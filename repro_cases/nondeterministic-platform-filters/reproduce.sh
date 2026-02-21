#!/bin/bash
#
# Reproduces nondeterministic PIF platform filter ordering.
#
# Uses xcodebuild to build a Swift package with multi-platform conditional
# dependencies. Each xcodebuild invocation gets a fresh process (and thus
# a fresh Swift hash seed), causing Set<PlatformFilter> to iterate in a
# different order during PIF serialization. This produces different build
# description signatures, preventing the on-disk cache from hitting.
#
# Usage:
#   cd repro_cases/nondeterministic-platform-filters
#   ./reproduce.sh
#
# Expected output (without fix):
#   Multiple distinct build description signatures across runs.
#
# Expected output (with fix):
#   Same signature every run.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RUNS=5
DERIVED_DATA="$SCRIPT_DIR/.deriveddata"

echo "Building $RUNS times with xcodebuild to check for nondeterministic PIF signatures..."
echo ""

signatures=()
for i in $(seq 1 $RUNS); do
    # Clean derived data to force fresh build planning
    rm -rf "$DERIVED_DATA"

    # Build using xcodebuild, which exercises swift-build's PIF serialization
    xcodebuild build \
        -scheme PlatformFilterRepro \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        -skipPackagePluginValidation \
        -quiet 2>/dev/null || true

    # Find the build description signature (the .xcbuilddata directory name)
    sig_dir=$(find "$DERIVED_DATA" -name "*.xcbuilddata" -type d 2>/dev/null | head -1)
    if [ -n "$sig_dir" ]; then
        sig=$(basename "$sig_dir" .xcbuilddata)
        signatures+=("$sig")
        printf "  Run %d: %s\n" "$i" "$sig"
    else
        echo "  Run $i: (no .xcbuilddata found)"
    fi
done

echo ""

unique=$(printf '%s\n' "${signatures[@]}" | sort -u | wc -l | tr -d ' ')
if [ "$unique" -gt 1 ]; then
    echo "REPRODUCED: $unique distinct signatures across $RUNS runs."
    echo ""
    echo "Each xcodebuild invocation produced a different build description"
    echo "signature due to nondeterministic Set<PlatformFilter> iteration"
    echo "order in PIF serialization. This prevents the BuildDescription"
    echo "on-disk cache from ever hitting."
else
    echo "All $RUNS runs produced the same signature."
    echo "The fix is working — platform filters are being sorted during"
    echo "PIF serialization, producing deterministic signatures."
fi

# Cleanup
rm -rf "$DERIVED_DATA"
