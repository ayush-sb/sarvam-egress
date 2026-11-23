#!/usr/bin/env bash
# The concurrency sweep behind bench.sh:  scripts/sweep.sh OUTPUT_DIR
#
# Three arms per level: no-gateway (SGLang's own server), default-gateway (stock Dynamo frontend) and
# optimized-gateway. The two gateway arms share one SGLang worker and alternate (odd rounds stock first).
# Per arm and level: RUNS cpu windows, 1 profile, 1 syscalls, then the latency windows (their timestamps
# change the worker, so they use a second worker). 2048 runs first.
#
# Set by bench.sh: MODEL, MODEL_PATH, BUILD_DIR, LEVELS, RUNS, LATENCY_RUNS, LATENCY_RUNS_2048.
# Each finished window is checked (scripts/checks.py); a rejected window or pair is measured again, up to
# 3 times in all, and then the sweep stops.
# The same OUTPUT_DIR again resumes. For testing on a small GPU: CHECKS=0 skips the checks and benchmark
# mode, and WINDOW, OUTPUT_TOKENS, OUTPUT_TOKENS_LOW, PROMPTS_PER_STREAM, SETTLE_SECONDS,
# CLIENT_WARMUP_REQUESTS and RUN_TIMEOUT change the workload.
#
# MOCK=1 (bench.sh --mock): Dynamo's mock engine (MOCKER_CONFIG) in place of SGLang, the Rust load generator as
# the client, and only the two gateway arms (cpu, profile and syscalls windows; no latency windows).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(realpath -m "${1:?usage: scripts/sweep.sh OUTPUT_DIR}")
: "${MODEL:?}" "${MODEL_PATH:?}" "${BUILD_DIR:?}"
source scripts/env.sh
builds=$(realpath "$BUILD_DIR")
export MODEL_PATH=$(realpath "$MODEL_PATH") SHAREGPT_DATASET=${SHAREGPT_DATASET:-$ROOT/config/workload/sharegpt-short.json}
checks=${CHECKS:-1} mock=${MOCK:-0}
say() { printf '%s  %s\n' "$(date +%T)" "$*"; }
die() { say "STOPPED: $*" >&2; exit 1; }

# Workload: 512 output tokens, a 20 s window. At 256 and 512 streams each stream makes one long request
# (1536 tokens), so a second wave of requests cannot start inside the window.
levels=${LEVELS:-256 512 1024 2048} rounds=${RUNS:-3}
latency_rounds=${LATENCY_RUNS:-1} latency_rounds_2048=${LATENCY_RUNS_2048:-2}
waves=${PROMPTS_PER_STREAM:-1} output_low=${OUTPUT_TOKENS_LOW:-1536} run_timeout=${RUN_TIMEOUT:-600}
if [[ $mock == 1 ]]; then   # the load generator runs for a fixed time: one output length at every level
    : "${MOCKER_CONFIG:?}"; export MOCKER_CONFIG=$(realpath "$MOCKER_CONFIG") OUTPUT_SPREAD=${OUTPUT_SPREAD:-300}
    OUTPUT_TOKENS=${OUTPUT_TOKENS:-1024}; output_low=$OUTPUT_TOKENS latency_rounds=0 latency_rounds_2048=0
fi
export WINDOW=${WINDOW:-20} OUTPUT_TOKENS=${OUTPUT_TOKENS:-512} SETTLE_SECONDS=${SETTLE_SECONDS:-3}
export CLIENT_WARMUP_REQUESTS=${CLIENT_WARMUP_REQUESTS:-16}
levels=$(printf '%s\n' $levels | sort -n | uniq | paste -sd' ')
[[ $checks == 0 || " $levels " == *" 2048 "* ]] || die "the levels must include 2048, the scored level"
sweep_order=$(printf '%s\n' $levels | awk '$1 == 2048 {print; next} {rest = rest " " $1} END {print rest}' | xargs)
latency_rounds_for() { if (($1 == 2048)); then echo "$latency_rounds_2048"; else echo "$latency_rounds"; fi; }

# Every arm starts from the same environment; only the optimized frontend gets its flags.
while read -r name; do unset "$name"; done < <(compgen -e | awk '/^(DYN_|SARVAM_STEP_TRACE)/')
unset FRONTEND_ENV GATEWAY_PYTHONPATH WORKER_PYTHONPATH LD_PRELOAD BENCH_PROMPTS
source scripts/env.sh
export HF_HUB_OFFLINE=1 CHECKS=$checks MOCK=$mock
export SGLANG_WORKER_ARGS=${SGLANG_WORKER_ARGS---freeze-gc-after-init}     # GC pauses in the worker stall delivery
# Engine settings the runner owns: room for every stream, one token per chunk, no prefix-cache hits
# between arms, prefill CUDA graphs off as in Dynamo's worker launcher.
max_running=4096
SGLANG_ARGS=${SGLANG_ARGS:-}
[[ " $SGLANG_ARGS " == *" --max-running-requests "* ]] && max_running=
export SGLANG_ARGS="$SGLANG_ARGS ${max_running:+--max-running-requests $max_running} --disable-radix-cache --cuda-graph-backend-prefill disabled --stream-interval 1 --decode-log-interval 8"
# SGLang's own server fills missing sampling fields from the model's defaults and Dynamo does not:
# send them explicitly so all arms sample alike (temperature 1.0 as the brief asks).
export SG_BENCH_REQUEST_BODY='{"temperature":1.0,"top_p":0.8,"top_k":20,"ignore_eos":true,"stream_options":{"include_usage":true}}'
export PYTORCH_CUDA_ALLOC_CONF=${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}

mkdir -p "$out"/{attempts,services}
exec 8>"$ROOT/results/.sweep.lock"; flock -n 8 || die "another sweep is running in this checkout"
./bench-mode.sh status > "$out/machine.txt"
if ! grep -q '^benchmark mode: *on$' "$out/machine.txt"; then
    [[ $checks == 0 ]] || die "benchmark mode is off (sudo ./bench-mode.sh on)"
    touch "$out/UNTUNED"
fi
[[ $(cat "$builds/recipe" 2>/dev/null) == final ]] || die "no builds in $builds (run ./setup.sh)"
(cd "$builds" && sha256sum --quiet -c binaries.sha256) || die "a library in $builds changed since setup"
jemalloc=$(ldconfig -p | awk '/libjemalloc\.so\.2 .*x86-64/ && !found {print $NF; found=1}')
BUNDLE_JEMALLOC=$jemalloc; source config/optimized.env; optimized_env=$FRONTEND_ENV
if [[ $mock == 1 ]]; then     # the mock engine's event rate needs more Tokio workers than the cloud preset
    optimized_env=$(sed -E "s/DYN_RUNTIME_NUM_WORKER_THREADS=[0-9]+/DYN_RUNTIME_NUM_WORKER_THREADS=${OPTIMIZED_WORKER_THREADS:-2}/" <<< "$optimized_env")
fi

# The settings of this run, kept with the results (table.md prints them). A resumed run must match.
{
    printf '%s\n' "model=$MODEL" "levels=$levels" "rounds=$rounds" "latency_rounds=$latency_rounds" \
        "latency_rounds_2048=$latency_rounds_2048" "window=$WINDOW" "output_tokens=$OUTPUT_TOKENS"
    if [[ $mock == 1 ]]; then
        printf '%s\n' "engine=Dynamo mock engine, $(jq -c . "$MOCKER_CONFIG")" "client=loadgen" \
            "output_tokens_spread=$OUTPUT_SPREAD"
    else
        printf '%s\n' "output_tokens_low=$output_low" "prompts_per_stream=$waves" "sglang_args=$SGLANG_ARGS" \
            "sglang_worker_args=$SGLANG_WORKER_ARGS" "request_body=$SG_BENCH_REQUEST_BODY"
    fi
    printf '%s\n' "optimized_env=$optimized_env" \
        "frontend_cpus=$FRONTEND_CPUS" "worker_cpus=$WORKER_CPUS" "client_cpus=$CLIENT_CPUS" \
        "housekeeping_cpus=$HOUSEKEEPING_CPUS" "host=$(hostname)" "kernel=$(uname -r)" "checks=$checks"
    sed 's/^/builds: /' "$builds/provenance.txt" 2>/dev/null || true
    if [[ $mock == 1 ]]; then lscpu | awk -F': *' '/^Model name/ {print "cpu: " $2}'
    else nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader; fi
} > "$out/config.pending"
if [[ -e $out/config.txt ]]; then
    cmp -s "$out/config.txt" "$out/config.pending" || die "settings differ from the run in $out; use a new output directory"
    rm "$out/config.pending"; say "resuming $out"
else
    mv "$out/config.pending" "$out/config.txt"
fi
[[ $checks == 0 ]] || bash scripts/preflight.sh "$out"

stop_services() { if [[ -n ${services:-} ]]; then RUN_DIR=$services scripts/serve.sh stop > /dev/null; fi; }
trap stop_services EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
table() { python3 scripts/table.py "$out" default-gateway > "$out/table.pending" && mv "$out/table.pending" "$out/table.md"; }

run() {   # LEVEL MODE ROUND, for the arm chosen by set_arm
    local c=$1 mode=$2 repeat=$3 key dir len=$OUTPUT_TOKENS
    ((c > 512)) || len=$output_low
    key=$VARIANT-c$c-$mode-r$repeat
    [[ ! -e $out/$key/summary.json ]] || return 0      # already done (resume)
    dir=$(mktemp -d "$out/attempts/$key.XXXXXXXX")
    printf '%s  %-18s %5s streams  %-8s round %s  ' "$(date +%T)" "$VARIANT" "$c" "$mode" "$repeat"
    if ! RUN_DIR=$services MEASURE_DIR=$dir CONCURRENCY=$c MODE=$mode OUTPUT_TOKENS=$len BENCH_PROMPTS=$((c * waves)) \
        timeout --kill-after=20 "$run_timeout" scripts/measure.sh > "$dir/measure.log" 2>&1 8>&-; then
        echo "FAILED"; tail -15 "$dir/measure.log" >&2; say "details: $dir"; return 1
    fi
    [[ -s $dir/summary.json ]] || { echo "FAILED (no summary)"; return 1; }
    if [[ $checks == 1 ]] && ! python3 scripts/checks.py window "$dir" "$c" "$mode" "$WINDOW" > /dev/null; then
        echo "REJECTED: $(jq -r '.errors | join("; ")' "$dir/gate.json")"; return 1
    fi
    jq -r '"\(.tokens_per_s) tokens/s, \(.frontend_cpu_s_per_1m_tokens) CPU-s per 1M tokens"' "$dir/summary.json"
    ln -s "attempts/${dir##*/}" "$out/$key" && table
}

set_arm() {
    VARIANT=$1 FRONTEND_ENV= GATEWAY_PYTHONPATH= WORKER_PYTHONPATH=$builds/worker
    local engine=sglang; [[ $mock == 0 ]] || engine=mocker
    case $VARIANT in
        no-gateway) ENGINE=sglang-direct ;;
        default-gateway) ENGINE=$engine GATEWAY_PYTHONPATH=$builds/pristine ;;
        optimized-gateway) ENGINE=$engine GATEWAY_PYTHONPATH=$builds/optimized FRONTEND_ENV=$optimized_env ;;
    esac
    export VARIANT ENGINE FRONTEND_ENV GATEWAY_PYTHONPATH WORKER_PYTHONPATH
}

gateway_pair() {   # LEVEL MODE ROUND: both gateway arms on the same worker, then compare them
    local c=$1 mode=$2 repeat=$3 arm order
    local a=$out/default-gateway-c$c-$mode-r$repeat b=$out/optimized-gateway-c$c-$mode-r$repeat
    unpair() { [[ ! -L $a ]] || unlink "$a"; [[ ! -L $b ]] || unlink "$b"; table || true; }
    if [[ -L $a && ! -L $b ]] || [[ -L $b && ! -L $a ]]; then unpair; fi     # redo a half-finished pair on one worker
    if ((repeat % 2)); then order="default-gateway optimized-gateway"; else order="optimized-gateway default-gateway"; fi
    for arm in $order; do set_arm "$arm"; run "$c" "$mode" "$repeat" || { unpair; return 1; }; done
    [[ $checks == 1 ]] || return 0
    local tolerance=0.05; [[ $mode == cpu ]] || tolerance=0.10   # instruments slow the two arms unevenly
    if ! python3 scripts/checks.py pair --rate-tolerance "$tolerance" "$a" "$b" > "$out/pair-c$c-$mode-r$repeat.json"; then
        say "REJECTED pair: $(jq -r '.errors | join("; ")' "$out/pair-c$c-$mode-r$repeat.json")"; unpair; return 1
    fi
    if [[ $mode == cpu && $mock == 0 ]]; then
        for arm in default-gateway optimized-gateway; do
            if ! python3 scripts/checks.py pair --direct "$out/no-gateway-c$c-cpu-r$repeat" "$out/$arm-c$c-cpu-r$repeat" \
                > "$out/direct-vs-$arm-c$c-r$repeat.json"; then
                say "REJECTED against no-gateway: $(jq -r '.errors | join("; ")' "$out/direct-vs-$arm-c$c-r$repeat.json")"; unpair; return 1
            fi
        done
    fi
}

attempts() {   # COMMAND...: a failed or rejected window (or pair) is measured again, up to 3 times in all.
    local attempt       # On cloud VMs the engine's own token rate drifts by a few percent between windows.
    for attempt in 1 2 3; do
        if "$@"; then return 0; fi
        ((attempt == 3)) || say "measuring again (attempt $((attempt + 1)) of 3)"
    done
    return 1
}

say "levels: $levels; $rounds cpu round(s) per arm and level; output: $out"
if [[ $mock == 0 ]]; then     # the mock engine has no server of its own: no SGLang-alone arm
    set_arm no-gateway
    services=$out/services/no-gateway-measurement
    for c in $sweep_order; do
        for ((r = 1; r <= rounds; r++)); do attempts run "$c" cpu "$r"; done
        attempts run "$c" profile 1; attempts run "$c" syscalls 1
    done
    stop_services
    services=$out/services/no-gateway-latency
    for c in $sweep_order; do for ((r = 1; r <= $(latency_rounds_for "$c"); r++)); do attempts run "$c" latency "$r"; done; done
    stop_services
fi
services=$out/services/gateway-measurement
for c in $sweep_order; do
    for ((r = 1; r <= rounds; r++)); do attempts gateway_pair "$c" cpu "$r"; done
    attempts gateway_pair "$c" profile 1; attempts gateway_pair "$c" syscalls 1
done
stop_services
services=$out/services/gateway-latency
for c in $sweep_order; do for ((r = 1; r <= $(latency_rounds_for "$c"); r++)); do attempts gateway_pair "$c" latency "$r"; done; done
stop_services
table
say "done: $out/table.md"
