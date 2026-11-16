#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
producer=${1:?usage: benches/run-tvos-simulator.sh PRODUCER_CHECKOUT EXISTING_TVOS_UDID}
device=${2:?provide an existing available tvOS simulator UDID}
library="$producer/target/artifacts/aarch64-apple-tvos-sim/release/liboscillux.a"
source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"]["sourceRevision"])' "$producer/dist/manifest.json")
sha=$(shasum -a 256 "$library" | cut -d ' ' -f 1)
scratch=$(mktemp -d /tmp/oscillux-bench-tvos.XXXXXX)
runner_pid=
cleanup() {
    if [ -f "$scratch/pid" ]; then
        read -r pid < "$scratch/pid"
        case "$pid" in ''|*[!0-9]*) ;; *)
            command=$(ps -p "$pid" -o args= 2>/dev/null || true)
            if [ "$command" = "$scratch/native-frame" ]; then kill "$pid" 2>/dev/null || true; fi ;;
        esac
    fi
    if [ -n "$runner_pid" ]; then kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Check target identity; standalone spawn requires no boot/clone and preserves existing device state.
xcrun simctl list devices available -j > "$scratch/devices.json"
python3 - "$scratch/devices.json" "$device" <<'PY'
import json, sys
records=json.load(open(sys.argv[1]))['devices']
found=[(runtime, d) for runtime, devices in records.items() for d in devices if d['udid']==sys.argv[2] and 'tvOS' in runtime and d['isAvailable']]
if len(found)!=1: raise SystemExit('requires an existing available tvOS device')
print(json.dumps({'simulator':found[0][1]['name'],'udid':sys.argv[2],'runtime':found[0][0],'originalState':found[0][1]['state'],'mode':'simctl spawn --standalone'}),file=sys.stderr)
PY
xcrun --sdk appletvsimulator clang -O3 -std=c11 -Wall -Wextra -Werror \
    -target arm64-apple-tvos18.0-simulator -I "$root/ffi/include" \
    "-DOSCILLUX_SOURCE=\"$source\"" "-DOSCILLUX_LIBRARY_SHA256=\"$sha\"" \
    "$root/benches/native-frame.c" "$library" -o "$scratch/native-frame"
SIMCTL_CHILD_OSCILLUX_BENCH_PIDFILE="$scratch/pid" xcrun simctl spawn --standalone "$device" "$scratch/native-frame" &
runner_pid=$!
wait "$runner_pid"
runner_pid=
