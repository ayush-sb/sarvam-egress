#!/usr/bin/env bash
# Before the first window: can this machine record every measurement?  scripts/preflight.sh OUTPUT_DIR
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1/preflight
mkdir -p "$out"
source scripts/env.sh
fail() { echo "preflight: $*" >&2; exit 1; }

[[ -d /run/sarvam-bench-state ]] || fail "benchmark mode is off (sudo ./bench-mode.sh on)"
files=$(ulimit -Sn); [[ $files == unlimited || $files -ge 16384 ]] || fail "open-file limit $files is too low for 2048 streams"
(( $(df -Pk "$out" | awk 'END {print $4}') >= 10 * 1024 * 1024 )) || fail "less than 10 GB free for results"
(( $(df -Pk /dev/shm | awk 'END {print $4}') >= 1024 * 1024 )) || fail "less than 1 GB free in /dev/shm (packet captures)"
[[ -z $(ss -H -ltn "sport = :${HTTP_PORT:-8000}") ]] || fail "port ${HTTP_PORT:-8000} is already in use"

# The frontend, worker, client and everything else must each have their own online CPUs.
python3 - "$FRONTEND_CPUS" "$WORKER_CPUS" "$CLIENT_CPUS" "$HOUSEKEEPING_CPUS" <<'PY' || fail "bad CPU layout (config/cpus.local.sh)"
import sys
def cpus(spec):
    out = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out
online, seen = cpus(open("/sys/devices/system/cpu/online").read().strip()), set()
for name, spec in zip(("frontend", "worker", "client", "housekeeping"), sys.argv[1:]):
    if not cpus(spec) <= online or seen & cpus(spec):
        sys.exit(f"{name} CPUs {spec} are offline or shared")
    seen |= cpus(spec)
PY

# Syscall counts, flame graphs and packet capture, as this user.
command -v inferno-collapse-perf > /dev/null && command -v inferno-flamegraph > /dev/null || fail "inferno is not installed (./setup.sh)"
perf stat -e syscalls:sys_enter_openat -o "$out/syscalls.txt" -- cat /dev/null 2> /dev/null &&
    grep -Eq '[1-9][0-9,]* +syscalls:sys_enter_openat' "$out/syscalls.txt" || fail "perf cannot count syscalls (benchmark mode makes the tracepoints readable)"
perf record -q -F 99 -g -o "$out/perf.data" -- python3 -c 'sum(range(30_000_000))' 2> /dev/null &&
    perf script -i "$out/perf.data" 2> /dev/null | inferno-collapse-perf > "$out/stacks.txt" && [[ -s $out/stacks.txt ]] || fail "perf cannot record stacks"
tcpdump -i lo -s 0 -c 1 --time-stamp-precision=nano -w "$out/loopback.pcap" 'udp dst port 39124' 2> /dev/null &
capture=$!
for _ in $(seq 20); do kill -0 "$capture" 2> /dev/null || break; echo capture-check > /dev/udp/127.0.0.1/39124; sleep 0.2; done
kill "$capture" 2> /dev/null && fail "tcpdump cannot capture on loopback as this user (./setup.sh grants it)"
wait "$capture" || true
(( $(stat -c %s "$out/loopback.pcap") > 24 )) || fail "tcpdump captured nothing on loopback"
echo "preflight passed"
