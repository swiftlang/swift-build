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

# DEBUG ONLY: characterize the FreeBSD stall where a process waits forever while
# its libdispatch manager thread and Foundation's process manager run loop spin.
#
# 1. Minimal reproducers: is an idle Swift process that waits on a child
#    process, or on a dispatch timer, spinning on FreeBSD?
# 2. Baseline: sample healthy swbuild/SWBBuildServiceBundle processes mid-build.
# 3. Stalls: repeat the stalling tests with an idle watchdog; on a stall, dump
#    stacks, decoded kevent arguments, syscall traces, and clock configuration.

set -u

IDLE_SECONDS=${IDLE_SECONDS:-120}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# The toolchain's lldb needs libpython3.11.
pkg install -y python311 > /dev/null || echo "warning: failed to install python311"
LLDB=$(command -v lldb || true)
if [ -n "$LLDB" ] && ! "$LLDB" --batch -o "version" > /dev/null; then
    echo "warning: lldb does not work, user stacks will be missing"
    LLDB=
fi

echo "===== environment"
uname -a
swift --version 2>&1 | head -2
sysctl hw.model hw.ncpu kern.timecounter.hardware kern.timecounter.choice kern.hz 2>&1
sysctl kern.vm_guest 2>&1

descendants() {
    local pid=$1 child
    for child in $(pgrep -P "$pid"); do # word splitting intended
        echo "$child"
        descendants "$child"
    done
}

# Prints per-thread CPU, a short syscall trace, and the process's CPU time over a few seconds.
sample_process() {
    local pid=$1
    echo "--- per-thread CPU (top -H)"
    top -H -b -d 1 -p "$pid" 2>&1 | sed -n '/^ *PID/,$p'
    echo "--- CPU time now and 5s later"
    ps -o time= -p "$pid"
    sleep 5
    ps -o time= -p "$pid"
    echo "--- truss (2s, first 120 lines)"
    timeout -s INT 2 truss -p "$pid" 2>&1 | head -n 120
    echo "--- syscall counts over 2s"
    timeout -s INT 2 truss -c -p "$pid" 2>&1 | tail -n 25
}

lldb_dump() {
    local pid=$1
    [ -n "$LLDB" ] || return 0
    echo "--- lldb user stacks and kevent arguments"
    # Decode the kevent arguments in every thread that is inside kevent().
    timeout 300 "$LLDB" --batch -O "settings set plugin.process.gdb-remote.packet-timeout 120" -p "$pid" \
        -o "thread backtrace all" \
        -o "script import lldb
p = lldb.debugger.GetSelectedTarget().GetProcess()
for t in p:
    f = t.GetFrameAtIndex(1)
    if f.GetFunctionName() != '__thr_kevent':
        continue
    print('=== thread #%d (tid %d) in kevent' % (t.GetIndexID(), t.GetThreadID()))
    n = f.FindVariable('nchanges').GetValueAsUnsigned()
    cl = f.FindVariable('changelist')
    for i in range(n):
        print('changelist[%d] = %s' % (i, cl.GetChildAtIndex(i, lldb.eDynamicCanRunTarget, True)))
    to = f.FindVariable('timeout')
    print('timeout = %s' % (to.Dereference() if to.GetValueAsUnsigned() else 'NULL (wait forever)'))
" 2>&1 | head -n 1500
}

dump_state() {
    local root=$1 pid
    local pids=()
    mapfile -t pids < <(echo "$root"; descendants "$root")
    echo "===== process tree"
    ps -axwwd -o pid,ppid,stat,etime,time,command
    echo "===== clock"
    sysctl kern.timecounter.hardware kern.boottime 2>&1
    date -u
    for pid in "${pids[@]}"; do
        echo "===== pid $pid: $(ps -o command= -p "$pid")"
        echo "--- procstat -kk (kernel stacks)"
        procstat -kk "$pid" 2>&1
        echo "--- procstat -f (open files)"
        procstat -f "$pid" 2>&1
        sample_process "$pid"
        lldb_dump "$pid"
    done
}

# Runs a command with line-buffered output and an idle watchdog.
# Returns 124 if the watchdog fired. If SAMPLE_BASELINE is 1, samples the
# swbuild and service processes of a healthy run once, a few seconds in.
run_with_watchdog() {
    local label=$1 idle=$2
    shift 2
    local log="/tmp/$label.log"
    : > "$log"
    echo "===== START $label at $(date -u +%FT%TZ): $*"
    stdbuf -oL -eL "$@" > "$log" 2>&1 &
    local pid=$!
    local printed=0 last_size=0 last_change sampled=0
    last_change=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do # ignore-unacceptable-language; POSIX API
        sleep 2
        local size
        size=$(stat -f %z "$log")
        if [ "$size" -ne "$last_size" ]; then
            last_size=$size
            last_change=$(date +%s)
        fi
        local lines
        lines=$(wc -l < "$log")
        if [ "$lines" -gt "$printed" ]; then
            sed -n "$((printed + 1)),${lines}p" "$log"
            printed=$lines
        fi
        if [ "${SAMPLE_BASELINE:-0}" = 1 ] && [ "$sampled" = 0 ]; then
            local cli
            cli=$(pgrep -f "swbuild build" | head -n 1)
            if [ -n "$cli" ]; then
                sampled=1
                sleep 3
                echo "===== $label BASELINE sample (healthy run so far)"
                local p
                for p in $cli $(descendants "$cli"); do # word splitting intended
                    if kill -0 "$p" 2>/dev/null; then # ignore-unacceptable-language; POSIX API
                        echo "===== baseline pid $p: $(ps -o command= -p "$p")"
                        sample_process "$p"
                    fi
                done
                echo "===== END BASELINE sample"
                last_change=$(date +%s)
            fi
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
PR943_COMMIT=${PR943_COMMIT:-a37eeb617695310da8cfd330c3af3eb413914d3b}
REPRO_DIR=/tmp/freebsd-repro
mkdir -p "$REPRO_DIR"

# Runs idle-process with no tracer attached; on a crash, re-runs it under lldb for a backtrace.
check_idle_process() {
    local tag=$1
    echo "===== idle-process clean run ($tag)"
    "$REPRO_DIR/idle-process" 5
    local rc=$?
    results+=("idle-process clean run ($tag): rc=$rc")
    if [ "$rc" -ne 0 ] && [ -n "$LLDB" ]; then
        echo "===== idle-process under lldb ($tag)"
        timeout 300 "$LLDB" --batch -O "settings set plugin.process.gdb-remote.packet-timeout 120" \
            -o "process handle SIGCHLD -s false -p true" -o run -k "thread backtrace all" -k "quit 1" \
            -- "$REPRO_DIR/idle-process" 5 2>&1 | head -n 300
    fi
}

# Builds libdispatch with swiftlang/swift-corelibs-libdispatch#943 and replaces the toolchain's copy.
patch_libdispatch() {
    pkg install -y cmake-core ninja git > /dev/null || pkg install -y cmake ninja git > /dev/null
    local src=/tmp/libdispatch-pr943
    rm -rf "$src"
    git clone -q https://github.com/swiftlang/swift-corelibs-libdispatch.git "$src" || return 1
    git -C "$src" fetch -q origin "pull/943/head" || return 1
    git -C "$src" checkout -q "$PR943_COMMIT" || return 1
    cmake -S "$src" -B "$src/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DENABLE_SWIFT=NO -DBUILD_TESTING=NO > /tmp/libdispatch-cmake.log 2>&1 || { tail -n 30 /tmp/libdispatch-cmake.log; return 1; }
    ninja -C "$src/build" dispatch > /tmp/libdispatch-build.log 2>&1 || { tail -n 30 /tmp/libdispatch-build.log; return 1; }
    local built target
    built=$(find "$src/build" -name 'libdispatch.so' | head -n 1)
    while IFS= read -r target; do
        echo "replacing $target"
        cp "$target" "$target.orig"
        cp "$built" "$target"
    done < <(find /opt/swift -name 'libdispatch.so' -type f)
}

restore_libdispatch() {
    local target
    while IFS= read -r target; do
        echo "restoring ${target%.orig}"
        cp "$target" "${target%.orig}"
    done < <(find /opt/swift -name 'libdispatch.so.orig' -type f)
}

# 1. idle-process crash, without truss, with the toolchain libdispatch and with #943.
swiftc -O "$SCRIPT_DIR/debug-freebsd-repro/idle-process.swift" -o "$REPRO_DIR/idle-process" || exit 1
check_idle_process "toolchain libdispatch"
if patch_libdispatch; then
    check_idle_process "libdispatch with #943"
    restore_libdispatch
else
    results+=("failed to build libdispatch with #943")
fi

# 2. Does clang on FreeBSD forward -u to the linker, and does profiling still work?
echo "===== clang -u forwarding"
printf 'int main(void) { return 0; }\n' > /tmp/u.c
clang -u __llvm_profile_runtime /tmp/u.c -o /tmp/u 2>&1
echo "--- clang -### link line"
clang -### -u __llvm_profile_runtime /tmp/u.c -o /tmp/u 2>&1 | grep -E '"(/usr/bin/)?ld' | tr ' ' '\n' | grep -nE '^"-u|__llvm_profile_runtime' || echo "(no -u in the link line)"
echo "--- swiftc -profile-generate"
printf 'print("hello")\n' > /tmp/prof.swift
(cd /tmp && rm -f default.profraw && swiftc -profile-generate -profile-coverage-mapping prof.swift -o prof 2>&1 && ./prof && ls -l default.profraw)
(cd /tmp && rm -f default.profraw && swiftc -emit-library -profile-generate -profile-coverage-mapping prof.swift -o libprof.so 2>&1 && echo "shared library linked")

# 3. and 4. Flaky swift-build tests, with the toolchain libdispatch as on real CI.
swift build --build-tests || exit 1
BIN_PATH=$(swift build --show-bin-path)
XCTEST=$(find "$BIN_PATH" -maxdepth 1 -name "*.xctest" | head -1)
echo "test bundle: $XCTEST"

run_flaky() {
    local test=$1 iterations=$2 i
    for i in $(seq 1 "$iterations"); do
        local attachments="/tmp/attachments-$test-$i"
        rm -rf "$attachments"
        mkdir -p "$attachments"
        run_with_watchdog "$test-$i" "$IDLE_SECONDS" "$XCTEST" --testing-library swift-testing --no-parallel \
            --filter "$test" --attachments-path "$attachments"
        local rc=$?
        results+=("$test iteration $i: rc=$rc")
        if [ "$rc" -ne 0 ]; then
            echo "===== $test-$i attachments"
            find "$attachments" -type f | while IFS= read -r f; do
                echo "--- $f"
                head -c 60000 "$f"
                echo
            done
        fi
    done
}

run_flaky singleFileCompile 15
run_flaky dynamicLibraryConsumingObjectLibraryWithCodeCoverage 3

echo "===== SUMMARY"
printf '%s\n' "${results[@]}"
