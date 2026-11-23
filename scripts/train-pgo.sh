#!/usr/bin/env bash
# PGO training (setup.sh --from-source): SGLang serves the benchmark model, the instrumented optimized
# frontend (BUILD_DIR/train, with config/optimized.env) is in front of it, and SGLang's benchmark client
# runs 512 and then 2048 streams. The frontend writes its profile when it exits; the profiles are merged
# into BUILD_DIR/pgo/merged.profdata for the optimized build.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$ROOT/config/model.env"
BUILD_DIR=$(realpath -m "${BUILD_DIR:-$ROOT/build}")
PGO=$BUILD_DIR/pgo
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$BUILD_DIR/build.log"; }
rm -rf "$PGO/raw"; mkdir -p "$PGO/raw"

BUNDLE_JEMALLOC=$(ldconfig -p | awk '/libjemalloc\.so\.2 .*x86-64/ && !found {print $NF; found=1}')
source "$ROOT/config/optimized.env"
export MODEL MODEL_PATH RUN_DIR=$PGO/service HTTP_PORT=18095
export GATEWAY_PYTHONPATH=$BUILD_DIR/train WORKER_PYTHONPATH=$BUILD_DIR/vanilla
export FRONTEND_ENV="$FRONTEND_ENV LLVM_PROFILE_FILE=$PGO/raw/%p-%m.profraw"
export SGLANG_ARGS="$SGLANG_ARGS --max-running-requests 2048 --disable-radix-cache --cuda-graph-backend-prefill disabled" SGLANG_WORKER_ARGS
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True    # as in the benchmark: large batches fragment the default allocator
mkdir -p "$RUN_DIR"
ulimit -Sn 65536 2>/dev/null || ulimit -Sn "$(ulimit -Hn)"  # 2048 streams need many open files
trap '"$ROOT/scripts/serve.sh" stop > /dev/null 2>&1 || true' EXIT

log "PGO training: starting SGLang ($MODEL) and the instrumented frontend"
"$ROOT/scripts/serve.sh" worker
for streams in 512 2048; do
    log "PGO training: $streams streams"
    taskset -c "$CLIENT_CPUS" "$ROOT/.venv-sglang/bin/python" -m sglang.bench_serving --backend sglang-oai-chat \
        --base-url "http://127.0.0.1:$HTTP_PORT" --model "$MODEL" --tokenizer "$MODEL_PATH" --dataset-name sharegpt \
        --dataset-path "$ROOT/config/workload/sharegpt-short.json" --seed 17 --max-concurrency "$streams" --num-prompts "$streams" \
        --sharegpt-output-len 512 --sharegpt-context-len 640 --output-file "$PGO/client-$streams.jsonl" \
        --extra-request-body '{"temperature":1.0,"top_p":0.8,"top_k":20,"ignore_eos":true,"stream_options":{"include_usage":true}}' \
        > "$PGO/client-$streams.log" 2>&1 || { log "the training client failed at $streams streams (see $PGO/client-$streams.log)"; exit 1; }
done

# The frontend writes its profile while it exits normally, which can take a while: stop it gently.
frontend=$(cat "$RUN_DIR/frontend.pid"); kill -TERM "$frontend"
for _ in $(seq 180); do kill -0 "$frontend" 2>/dev/null || break; sleep 0.5; done
compgen -G "$PGO/raw/*.profraw" > /dev/null || { log "no profile was written (see $RUN_DIR/frontend.log)"; exit 1; }
toolchain=$(awk -F'"' '/channel/ {print $2}' "$ROOT/rust-toolchain.toml")
"$(rustc +"$toolchain" --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata" merge -o "$PGO/merged.profdata" "$PGO"/raw/*.profraw
log "PGO training done: $PGO/merged.profdata"
