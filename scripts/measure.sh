#!/usr/bin/env bash
# One measured window at one concurrency level (sweep.sh calls it).
#
#   ENGINE=sglang|sglang-direct|mocker VARIANT=NAME MODE=cpu|profile|syscalls|latency CONCURRENCY=N \
#       MEASURE_DIR=DIR scripts/measure.sh
#
# ENGINE=sglang: the Dynamo frontend (GATEWAY_PYTHONPATH, FRONTEND_ENV) in front of Dynamo's SGLang worker
# (WORKER_PYTHONPATH). The worker keeps running when only the frontend changes, so the gateway arms share it.
# ENGINE=sglang-direct: SGLang's own HTTP server, no gateway.
# ENGINE=mocker: the Dynamo frontend in front of Dynamo's mock engine (MOCKER_CONFIG), with the Rust load
# generator in loadgen/ as the client (OUTPUT_TOKENS +- OUTPUT_SPREAD tokens per request). No latency mode.
#
# MODE=cpu       CPU per token, client timing; nothing attached
# MODE=profile   perf record on the frontend (or SGLang's server process) -> flame.svg
# MODE=syscalls  perf stat on the syscall tracepoints, and a packet capture for bytes per token
# MODE=latency   timestamps in the worker (each frame) and the scheduler (each step), matched to the
#                packets on loopback: emit-to-wire latency
#
# The window opens when CONCURRENCY streams are active plus SETTLE_SECONDS, and lasts WINDOW seconds.
# CHECKS=1 also records what scripts/checks.py needs to accept the window.
set -euo pipefail
source "$(dirname "$0")/env.sh"
: "${MEASURE_DIR:?}" "${ENGINE:?}" "${VARIANT:?}" "${MODE:?}" "${CONCURRENCY:?}" "${MODEL:?}" "${MODEL_PATH:?}"
OUT=$MEASURE_DIR C=$CONCURRENCY WINDOW=${WINDOW:-20} OSL=${OUTPUT_TOKENS:-512} PROMPTS=${BENCH_PROMPTS:-$((2 * CONCURRENCY))}
mkdir -p "$OUT"
[ "$ENGINE" != mocker ] || [ "$MODE" != latency ] || { echo "the mock engine has no emit timestamps: no latency mode"; exit 1; }

CLIENT_PID= TD= SAMPLER=
cleanup() {   # leave nothing running, whatever happened
    local status=$?
    set +e
    for p in $CLIENT_PID $SAMPLER; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
    [ -z "$TD" ] || kill "$TD" 2>/dev/null
    [ "$status" = 0 ] || "$ROOT/scripts/serve.sh" stop > /dev/null 2>&1
    rm -f "/dev/shm/sarvam-$$.pcap"
    return "$status"
}
trap cleanup EXIT
trap 'echo "measure.sh stopped at line $LINENO: $BASH_COMMAND"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
"$ROOT/bench-mode.sh" status > "$OUT/machine.txt"

# Latency windows put timestamps in the worker; that needs a worker started with them.
unset DYN_BENCH_EMIT_TS SARVAM_STEP_TRACE
if [ "$MODE" = latency ]; then export DYN_BENCH_EMIT_TS=1 SARVAM_STEP_TRACE=1; fi

# Start what this window needs: a new worker when its settings change, else only a new frontend.
if [ "$ENGINE" = sglang-direct ]; then
    worker_config="direct ${DYN_BENCH_EMIT_TS:-0} $SGLANG_ARGS" frontend_config=none
elif [ "$ENGINE" = mocker ]; then
    worker_config="mock ${WORKER_PYTHONPATH:-} ${MOCKER_CONFIG:?} $(sha256sum < "$MOCKER_CONFIG")"
    frontend_config="${GATEWAY_PYTHONPATH:-} ${FRONTEND_ENV:-}"
else
    worker_config="worker ${DYN_BENCH_EMIT_TS:-0} ${WORKER_PYTHONPATH:-} $SGLANG_ARGS ${SGLANG_WORKER_ARGS:-}"
    frontend_config="${GATEWAY_PYTHONPATH:-} ${FRONTEND_ENV:-}"
fi
running=$RUN_DIR/running-config
alive() { kill -0 "$(cat "$RUN_DIR/$1.pid" 2>/dev/null)" 2>/dev/null; }
if [ "$(sed -n 1p "$running" 2>/dev/null)" != "$worker_config" ] || ! alive worker; then
    "$ROOT/scripts/serve.sh" stop > /dev/null
    case $ENGINE in
        sglang-direct) "$ROOT/scripts/serve.sh" direct ;;
        mocker) "$ROOT/scripts/serve.sh" mock ;;
        *) "$ROOT/scripts/serve.sh" worker ;;
    esac > "$OUT/start.txt"
elif [ "$ENGINE" != sglang-direct ] && { [ "$(sed -n 2p "$running")" != "$frontend_config" ] || ! alive frontend; }; then
    "$ROOT/scripts/serve.sh" stop frontend
    "$ROOT/scripts/serve.sh" frontend > "$OUT/start.txt"
fi
printf '%s\n' "$worker_config" "$frontend_config" > "$running"

WP=$(cat "$RUN_DIR/worker.pid")   # the worker, or SGLang's own server: leader of its process group
if [ "$ENGINE" = sglang-direct ]; then
    FP=$WP                            # the process that owns the client connections
    ENGINE_CPUS=$FRONTEND_CPUS,$WORKER_CPUS
    TOK_METRIC='sglang:realtime_tokens_total{engine_type="unified",mode="decode"' INFLIGHT_METRIC='sglang:num_running_reqs{'
else
    FP=$(cat "$RUN_DIR/frontend.pid")
    ENGINE_CPUS=$WORKER_CPUS
    TOK_METRIC='dynamo_frontend_output_tokens_total' INFLIGHT_METRIC='dynamo_frontend_inflight_requests'
    # Each arm must run the library it names.
    grep -qF "$(realpath "$GATEWAY_PYTHONPATH/dynamo/_core.abi3.so")" "/proc/$FP/maps" || { echo "the frontend loaded another library"; exit 1; }
    grep -qF "$(realpath "$WORKER_PYTHONPATH/dynamo/_core.abi3.so")" "/proc/$WP/maps" || { echo "the worker loaded another library"; exit 1; }
fi
printf '%s %s\n' "$WP" "$(awk '{print $22}' "/proc/$WP/stat")" > "$OUT/worker-id.txt"   # pid and start time

ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }        # user + system CPU of a process
group_ticks() { local t=0 p; for p in $(pgrep -g "$1"); do t=$((t + $(ticks "$p"))); done; echo $t; }
metric() { awk -v m="$1" 'index($0, m) == 1 {s += $NF} END {printf "%d", s + 0}'; }
snap() {   # [before-scrape]: CPU of the frontend and the worker group, tokens delivered, streams in flight
    local m t_ns=
    if [ "${1:-}" = before-scrape ]; then t_ns=$(date +%s%N); fi      # latency windows align the capture to this
    m=$(curl -fs --max-time 3 "http://localhost:$HTTP_PORT/metrics") || return 1
    printf '{"t_ns":%s,"frontend_ticks":%s,"worker_ticks":%s,"worker_main_ticks":%s,"tokens":%s,"inflight":%s}\n' \
        "${t_ns:-$(date +%s%N)}" "$(ticks "$FP")" "$(group_ticks "$WP")" "$(ticks "$WP")" \
        "$(metric "$TOK_METRIC" <<< "$m")" "$(metric "$INFLIGHT_METRIC" <<< "$m")"
}
inflight() { curl -s --max-time 2 "http://localhost:$HTTP_PORT/metrics" | metric "$INFLIGHT_METRIC"; }
tokens() { curl -s --max-time 2 "http://localhost:$HTTP_PORT/metrics" | metric "$TOK_METRIC"; }
log_size() { stat -c %s "$RUN_DIR/worker.log"; }

log_start=$(log_size)
client_started=$(date +%s)
if [ "$ENGINE" = mocker ]; then
    # The load: the Rust load generator holds C streams open for a fixed time; each request asks for
    # OUTPUT_TOKENS +- OUTPUT_SPREAD tokens. It records every event's arrival after its 8 s warm-up.
    LOADGEN=$ROOT/loadgen/target/release/loadgen
    [ -x "$LOADGEN" ] || { echo "build the load generator first: ./setup.sh --mock"; exit 1; }
    taskset -c "$CLIENT_CPUS" "$LOADGEN" --addr "127.0.0.1:$HTTP_PORT" --model "$MODEL" --concurrency "$C" \
        --max-tokens "$OSL" --spread "${OUTPUT_SPREAD:-300}" --warmup 8 --ramp 2 --duration "$((WINDOW + 30))" \
        --raw "$OUT/arrivals.csv" --out "$OUT/loadgen.json" > "$OUT/client.log" 2>&1 &
else
    # The load: SGLang's benchmark client with the pinned prompt set, fixed output length.
    echo "$PROMPTS" > "$OUT/expected-prompts.txt"
    taskset -c "$CLIENT_CPUS" "$ROOT/.venv-sglang/bin/python" -m sglang.bench_serving \
        --backend sglang-oai-chat --base-url "http://127.0.0.1:$HTTP_PORT" --model "$MODEL" --tokenizer "$MODEL_PATH" \
        --dataset-name sharegpt --dataset-path "$SHAREGPT_DATASET" --seed 42 --max-concurrency "$C" --num-prompts "$PROMPTS" \
        --warmup-requests "${CLIENT_WARMUP_REQUESTS:-16}" --sharegpt-output-len "$OSL" --sharegpt-context-len "$((OSL + 128))" \
        --extra-request-body "$SG_BENCH_REQUEST_BODY" --output-details --output-file "$OUT/sglang-client.jsonl" > "$OUT/client.log" 2>&1 &
fi
CLIENT_PID=$!
need=$(((C * 98 + 99) / 100))
for i in $(seq 180); do
    kill -0 $CLIENT_PID 2>/dev/null || { echo "the client exited before reaching $C streams; see $OUT/client.log"; exit 1; }
    [ "$(inflight)" -lt "$need" ] || break
    [ "$i" -lt 180 ] || { echo "never reached $need active streams"; exit 1; }
    sleep 1
done
# All streams are active once their requests are in, but on a cold machine prefill can still take a while:
# wait until the streams are decoding (twice as many tokens delivered as there are streams).
first=$(tokens)
for i in $(seq 240); do
    [ "$(tokens)" -lt "$((first + 2 * C))" ] || break
    [ "$i" -lt 240 ] || { echo "the streams did not start decoding within 120 s"; exit 1; }
    sleep 0.5
done
if [ "${CHECKS:-1}" = 1 ]; then
    taskset -c "$HOUSEKEEPING_CPUS" python3 "$ROOT/scripts/checks.py" sample "http://127.0.0.1:$HTTP_PORT/metrics" "$ENGINE" \
        > "$OUT/load-samples.jsonl" &
    SAMPLER=$!
fi
sleep "${SETTLE_SECONDS:-3}"
if [ "$ENGINE" = mocker ]; then      # the load generator records arrivals only after its 8 s warm-up
    while [ $(( $(date +%s) - client_started )) -lt 9 ]; do sleep 0.2; done
fi

# Latency and syscalls windows capture the responses on loopback (a few seconds of margin on each side).
if [ "$MODE" = latency ] || [ "$MODE" = syscalls ]; then
    PCAP=/dev/shm/sarvam-$$.pcap
    margin=3; [ "$MODE" = latency ] || margin=8       # perf stat starts inside the syscalls capture
    LC_ALL=C taskset -c "$HOUSEKEEPING_CPUS" tcpdump -i lo -s 0 -B 524288 --time-stamp-precision=nano \
        -G "$((WINDOW + margin))" -W 1 -w "$PCAP" "ip and tcp src port $HTTP_PORT and dst host 127.0.0.1" 2> "$OUT/tcpdump.err" &
    TD=$!
    for i in $(seq 50); do grep -q '^tcpdump: listening on ' "$OUT/tcpdump.err" && break; sleep 0.02; done
    grep -q '^tcpdump: listening on ' "$OUT/tcpdump.err" || { cat "$OUT/tcpdump.err"; exit 1; }
    sleep 0.25
fi

# The window. Per-process CPU comes from the snapshots; pidstat and mpstat show threads and cores.
clock_offset() { python3 -S -c 'import time; print(time.time_ns() - time.monotonic_ns())'; }
clock_before=$(clock_offset)
log_a=$(log_size)
pidstat -u -t -p "$FP" 1 "$WINDOW" > "$OUT/pidstat_frontend.txt" 2>&1 &
pidstat -u -t -p "$(pgrep -g "$WP" | paste -sd,)" 1 "$WINDOW" > "$OUT/pidstat_worker.txt" 2>&1 &
pidstat -u -t -p "$CLIENT_PID" 1 "$WINDOW" > "$OUT/pidstat_client.txt" 2>&1 &
pidstat_client=$!
mpstat -P ALL 1 "$WINDOW" > "$OUT/mpstat.txt" 2>&1 &
# perf -p exits with 255 when a thread exits while perf attaches (Tokio's blocking pool); nothing was
# measured then, so try again. Both snapshots run inside perf's command, so neither perf's start-up
# nor its shutdown counts toward the window.
perf_attach() {   # perf ARGS...
    for attempt in 1 2 3 4 5; do
        if "$@"; then return 0; fi
        [ ! -s "$OUT/snap_a.json" ] && [ "$attempt" != 5 ] || return 1
        sleep 0.2
    done
}
export FP WP TOK_METRIC INFLIGHT_METRIC HTTP_PORT
export -f ticks group_ticks metric snap
window_command='snap > "$1"; sleep "$3"; snap > "$2"'
case $MODE in
    cpu) snap > "$OUT/snap_a.json"; sleep "$WINDOW"; snap > "$OUT/snap_b.json" ;;
    latency) snap before-scrape > "$OUT/snap_a.json"; sleep "$WINDOW"; snap before-scrape > "$OUT/snap_b.json" ;;
    profile)   # -N: perf reads the libraries in place instead of copying them (760 MB each) to ~/.debug
        perf_attach perf record -q -N -F 999 -g -p "$FP" -o "$OUT/perf.data" -- \
            bash -ec "$window_command" _ "$OUT/snap_a.json" "$OUT/snap_b.json" "$WINDOW" 2>> "$OUT/perf.err" ;;
    syscalls)
        perf_attach perf stat -e 'syscalls:sys_enter_*' -p "$FP" -o "$OUT/syscalls.txt" -- \
            bash -ec "$window_command" _ "$OUT/snap_a.json" "$OUT/snap_b.json" "$WINDOW" 2>> "$OUT/perf.err" \
            || { echo "perf cannot read the syscall tracepoints (sudo ./bench-mode.sh on)"; exit 1; } ;;
    *) echo "unknown MODE=$MODE"; exit 1 ;;
esac
log_b=$(log_size)
printf '{"realtime_minus_monotonic_ns":[%s,%s]}\n' "$clock_before" "$(clock_offset)" > "$OUT/clock.json"
tail -c "+$((log_a + 1))" "$RUN_DIR/worker.log" | head -c "$((log_b - log_a))" > "$OUT/worker-window.log" || true
kill -0 "$CLIENT_PID" 2>/dev/null || { echo "the client finished before the window closed"; exit 1; }

# After the window: let the capture close (it rotates on the next packet) and the client finish.
if [ -n "$TD" ]; then
    for i in $(seq 14); do
        kill -0 "$TD" 2>/dev/null || break
        [ "$i" -lt 4 ] || curl -s --max-time 1 "http://localhost:$HTTP_PORT/v1/models" > /dev/null || true
        [ "$i" -lt 14 ] || { echo "tcpdump did not close its capture"; exit 1; }
        sleep 1
    done
    wait "$TD" || true; TD=
fi
wait "$CLIENT_PID"; CLIENT_PID=
wait "$pidstat_client" || true
tail -c "+$((log_start + 1))" "$RUN_DIR/worker.log" > "$OUT/worker-after-launch.log"   # KV retractions, if any
[ -z "$SAMPLER" ] || { kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null || true; SAMPLER=; }

case $MODE in
    profile)
        perf script -i "$OUT/perf.data" 2> /dev/null | inferno-collapse-perf > "$OUT/frontend.folded"
        inferno-flamegraph --title "$VARIANT, $C streams" "$OUT/frontend.folded" > "$OUT/flame.svg"
        rm -f "$OUT/perf.data" ;;
    latency)
        python3 "$ROOT/scripts/wire_latency.py" "$PCAP" "$OUT/tcpdump.err" --require-step-stamps \
            --window "$OUT/snap_a.json" "$OUT/snap_b.json" --events-out "$OUT/wire-events.jsonl" > "$OUT/wire_latency.json"
        jq -e '.stamped_events > 0 and .dropped_by_kernel == 0 and .sequence_gaps == 0 and .ambiguous_overlaps == 0 and .negative_latencies == 0' \
            "$OUT/wire_latency.json" > /dev/null || { echo "unusable latency capture; see wire_latency.json"; exit 1; } ;;
    syscalls)
        python3 "$ROOT/scripts/wire_latency.py" "$PCAP" "$OUT/tcpdump.err" --window "$OUT/snap_a.json" "$OUT/snap_b.json" \
            > "$OUT/wire_bytes.json" ;;
esac
"$DYN_PY" "$ROOT/scripts/analyze.py" "$OUT" --concurrency "$C" --mode "$MODE" --engine "$ENGINE" --variant "$VARIANT" \
    --frontend-cpus "$FRONTEND_CPUS" --engine-cpus "$ENGINE_CPUS" --client-cpus "$CLIENT_CPUS" > /dev/null
[ "$ENGINE" != mocker ] || zstd -q -f --rm "$OUT/arrivals.csv"      # every event's arrival time, kept compressed
