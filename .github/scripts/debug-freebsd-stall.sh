#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See http://swift.org/LICENSE.txt for license information
## See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

# DEBUG ONLY: locate tests that stall on FreeBSD.
#
# `swift test` output is block-buffered on FreeBSD CI, so the log doesn't show
# which test stalls. Run the swift-testing pass of the test bundle directly
# with line-buffered output and a watchdog. When there's no new output for a
# while, dump the process tree, kernel and user stacks, and open files of the
# test process and its descendants, then terminate them.

set -u

IDLE_SECONDS=${IDLE_SECONDS:-120}
ITERATIONS=${ITERATIONS:-25}
MAX_STALLS=${MAX_STALLS:-2}

# The toolchain's lldb needs libpython3.11; gdb attaches more reliably under QEMU.
pkg install -y python311 gdb > /dev/null || echo "warning: failed to install python311/gdb"
GDB=$(command -v gdb || true)
echo "gdb: ${GDB:-<none>}"

swift build --build-tests || exit 1
BIN_PATH=$(swift build --show-bin-path)
XCTEST=$(find "$BIN_PATH" -maxdepth 1 -name "*.xctest" | head -1)
echo "test bundle: $XCTEST"
LLDB=$(command -v lldb || true)
echo "lldb: ${LLDB:-<none>}"
if [ -n "$LLDB" ] && ! "$LLDB" --batch -o "version"; then
    echo "warning: lldb does not work, user stacks will be missing"
    LLDB=
fi

descendants() {
    local pid=$1 child
    for child in $(pgrep -P "$pid"); do # word splitting intended
        echo "$child"
        descendants "$child"
    done
}

dump_state() {
    local root=$1 pid
    local pids=()
    mapfile -t pids < <(echo "$root"; descendants "$root")
    echo "===== process tree"
    ps -axwwd -o pid,ppid,stat,etime,time,command
    for pid in "${pids[@]}"; do
        echo "===== pid $pid: $(ps -o command= -p "$pid")"
        echo "--- procstat -kk (kernel stacks)"
        procstat -kk "$pid" 2>&1
        echo "--- procstat -f (open files)"
        procstat -f "$pid" 2>&1
        echo "--- per-thread CPU (top -H)"
        top -H -b -d 1 -p "$pid" 2>&1 | tail -n 20
        if [ -n "$GDB" ]; then
            echo "--- gdb user stacks"
            timeout 300 "$GDB" -p "$pid" -batch -ex "set pagination off" -ex "thread apply all bt 40" 2>&1 | grep -v "^\[New LWP" | head -1500
        fi
        if [ -n "$LLDB" ]; then
            echo "--- lldb user stacks"
            timeout 300 "$LLDB" --batch -O "settings set plugin.process.gdb-remote.packet-timeout 120" -p "$pid" -o "thread backtrace all" 2>&1 | head -1500
        fi
        echo "--- procstat -kk again (10s later)"
        sleep 10
        procstat -kk "$pid" 2>&1
    done
    echo "===== PTY holders"
    fstat 2>/dev/null | grep -E "pts/|ptmx" | head -50
}

# Runs a command with line-buffered output and an idle watchdog.
# Returns 124 if the watchdog fired.
run_with_watchdog() {
    local label=$1 idle=$2
    shift 2
    local log="/tmp/$label.log"
    : > "$log"
    echo "===== START $label at $(date -u +%FT%TZ): $*"
    stdbuf -oL -eL "$@" > "$log" 2>&1 &
    local pid=$!
    local printed=0 last_size=0 last_change
    last_change=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do # ignore-unacceptable-language; POSIX API
        sleep 5
        local size
        size=$(stat -f %z "$log")
        if [ "$size" -ne "$last_size" ]; then
            last_size=$size
            last_change=$(date +%s)
        fi
        # Stream new lines into the CI log.
        local lines
        lines=$(wc -l < "$log")
        if [ "$lines" -gt "$printed" ]; then
            sed -n "$((printed + 1)),${lines}p" "$log"
            printed=$lines
        fi
        if [ $(( $(date +%s) - last_change )) -ge "$idle" ]; then
            echo "===== $label STALLED: no output for ${idle}s at $(date -u +%FT%TZ)"
            echo "===== last output lines:"
            tail -n 15 "$log"
            dump_state "$pid"
            local stalled=()
            mapfile -t stalled < <(echo "$pid"; descendants "$pid")
            kill -KILL "${stalled[@]}" 2>/dev/null # ignore-unacceptable-language; POSIX API
            wait "$pid" 2>/dev/null
            echo "===== END $label: STALLED"
            return 124
        fi
    done
    wait "$pid"
    local rc=$?
    sed -n "$((printed + 1)),\$p" "$log"
    echo "===== END $label: exit $rc at $(date -u +%FT%TZ)"
    return $rc
}

results=()
stalls=0

for i in $(seq 1 "$ITERATIONS"); do
    run_with_watchdog "buildCommandWithUserDefaults-$i" "$IDLE_SECONDS" "$XCTEST" --testing-library swift-testing --no-parallel --filter buildCommandWithUserDefaults
    rc=$?
    results+=("buildCommandWithUserDefaults iteration $i: rc=$rc")
    if [ "$rc" -eq 124 ]; then
        stalls=$((stalls + 1))
        [ "$stalls" -ge "$MAX_STALLS" ] && break
    fi
done

echo "===== SUMMARY"
printf '%s\n' "${results[@]}"
