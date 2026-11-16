#!/system/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Private to one unique benchmark directory. No device-wide process operations.
set -eu
cd "$(dirname "$0")"
remote=$PWD
proc_root=/proc
identity() {
    pid=$1
    start=$(sed 's/^.*) //' "$proc_root/$pid/stat" | awk '{print $20}') || return 1
    case "$start" in ''|*[!0-9]*) return 1;; esac
    printf '%s %s\n' "$pid" "$start"
}
state() {
    name=$1
    if [ ! -f "$name.identity" ]; then
        if [ "$name" = native ] && [ -e NATIVE_PENDING ]; then printf 'UNKNOWN\n'; else printf 'ABSENT\n'; fi
        return
    fi
    read -r pid expected < "$name.identity" || { printf 'UNKNOWN\n'; return; }
    case "$pid:$expected" in *[!0-9:]*|:*|*:) printf 'UNKNOWN\n'; return;; esac
    if ! kill -0 "$pid" 2>/dev/null; then
        if [ -d "$proc_root/$pid" ]; then printf 'UNKNOWN\n'; else printf 'ABSENT\n'; fi
        return
    fi
    observed=$(identity "$pid") || { printf 'UNKNOWN\n'; return; }
    command=$(tr '\000' '\n' < "$proc_root/$pid/cmdline") || { printf 'UNKNOWN\n'; return; }
    if [ "$observed" != "$pid $expected" ]; then printf 'UNKNOWN\n'; return; fi
    case "$name" in
      native) first=$(printf '%s\n' "$command" | head -n 1); [ "$first" = "$remote/native-frame" ] || { printf 'UNKNOWN\n'; return; };;
      runner) printf '%s\n' "$command" | grep -Fx "$remote/android-control.sh" >/dev/null || { printf 'UNKNOWN\n'; return; };;
    esac
    printf 'OWNED\n'
}
lock() {
    n=0
    until mkdir control.lock 2>/dev/null; do
        n=$((n + 1)); [ "$n" -lt 30 ] || return 1
        sleep 0.1
    done
}
retire() {
    name=$1
    status=$(state "$name")
    [ "$status" != UNKNOWN ] || return 1
    [ "$status" != ABSENT ] || return 0
    read -r pid unused < "$name.identity"
    kill -TERM "$pid" 2>/dev/null || return 1
    n=0
    while [ "$n" -lt 30 ]; do
        status=$(state "$name")
        [ "$status" != ABSENT ] || return 0
        [ "$status" != UNKNOWN ] || return 1
        n=$((n + 1)); sleep 0.1
    done
    return 1
}
case "${1:-}" in
 run)
    # Cleanup marks CANCEL before taking this same lock: a delayed launcher cannot
    # start native work after cleanup has proved retirement and removed the directory.
    lock || exit 90
    owns_lock=1
    child=
    finish_run() {
        # Before identity publication, parenthood identifies the still-unreaped child.
        # A reused PID cannot be mistaken for it after wait has reaped it.
        if [ -n "$child" ] && [ -r "$proc_root/$child/stat" ]; then
            parent=$(sed 's/^.*) //' "$proc_root/$child/stat" | awk '{print $2}')
            if [ "$parent" = "$$" ]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
        fi
        if [ "$owns_lock" = 1 ]; then rmdir control.lock 2>/dev/null || true; fi
    }
    trap finish_run EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    [ ! -e CANCEL ] || exit 90
    identity "$$" > runner.identity
    : > NATIVE_PENDING
    LD_LIBRARY_PATH="$remote" "$remote/native-frame" &
    child=$!
    identity "$child" > native.identity || exit 90
    rm NATIVE_PENDING
    rmdir control.lock
    owns_lock=0
    wait "$child"
    ;;
 cleanup)
    : > CANCEL
    lock || { printf 'UNKNOWN lock unavailable\n'; exit 90; }
    trap 'rmdir control.lock 2>/dev/null || true' EXIT
    retire native && retire runner || { printf 'UNKNOWN retirement unproved\n'; exit 90; }
    # Only the host removes this directory, after seeing this exact acknowledgement.
    printf 'RETIRED\n'
    ;;
 *) exit 2;;
esac
