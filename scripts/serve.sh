#!/usr/bin/env bash
# Start and stop the processes the benchmark talks to. Logs and pid files go to RUN_DIR.
#
#   scripts/serve.sh worker           Dynamo's SGLang worker (native library: WORKER_PYTHONPATH) and a frontend
#   scripts/serve.sh frontend         only a new frontend (GATEWAY_PYTHONPATH, FRONTEND_ENV), same worker
#   scripts/serve.sh direct           SGLang's own HTTP server, no gateway, on the frontend + worker cores
#   scripts/serve.sh mock             Dynamo's mock engine (Rust, no GPU; MOCKER_CONFIG) and a frontend
#   scripts/serve.sh stop [frontend]  stop everything, or only the frontend
#
# Needs MODEL, MODEL_PATH and SGLANG_ARGS (SGLANG_WORKER_ARGS: options for Dynamo's worker only).
# The mock engine needs MODEL, MODEL_PATH (the tokenizer files) and MOCKER_CONFIG.
set -euo pipefail
source "$(dirname "$0")/env.sh"
sglang=$ROOT/.venv-sglang
# SGLang compiles some kernels at its first start, with nvcc and ninja from its own environment.
export CUDA_HOME=$sglang/lib/python3.12/site-packages/nvidia/cu13 PATH=$sglang/bin:$sglang/lib/python3.12/site-packages/nvidia/cu13/bin:$PATH

wait_ready() {   # SECONDS PROCESS...: until the model is listed, while the processes stay alive
    local limit=$1 i p; shift
    for i in $(seq "$limit"); do
        for p in "$@"; do
            kill -0 "$(cat "$RUN_DIR/$p.pid")" 2>/dev/null || { echo "the $p process died:"; tail -20 "$RUN_DIR/$p.log"; exit 1; }
        done
        if curl -sf "http://localhost:$HTTP_PORT/v1/models" | grep -Fq "$MODEL"; then echo "ready after ${i}s"; return; fi
        sleep 1
    done
    echo "the model did not appear within ${limit}s; see $RUN_DIR/*.log"; exit 1
}
port_free() { if ss -ltn | grep -q ":$HTTP_PORT\b"; then echo "port $HTTP_PORT is in use"; exit 1; fi; }
start_frontend() {
    setsid taskset -c "$FRONTEND_CPUS" env "PYTHONPATH=${GATEWAY_PYTHONPATH:-}" ${FRONTEND_ENV:-} \
        "$DYN_PY" -m dynamo.frontend --router-mode round-robin --http-port "$HTTP_PORT" > "$RUN_DIR/frontend.log" 2>&1 &
    echo $! > "$RUN_DIR/frontend.pid"
}
stop() {   # PROCESS...: each one's whole process group
    local p pid
    for p in "$@"; do
        [ -f "$RUN_DIR/$p.pid" ] || continue
        pid=$(cat "$RUN_DIR/$p.pid"); kill -TERM -- "-$pid" 2>/dev/null || true
        for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
        kill -KILL -- "-$pid" 2>/dev/null || true      # whatever is left of the group; usually nothing
        rm -f "$RUN_DIR/$p.pid"
    done
    for _ in $(seq 40); do ss -ltn | grep -q ":$HTTP_PORT\b" || break; sleep 0.25; done
}

case ${1:-} in
    worker)
        port_free; rm -rf "$DYN_FILE_KV"
        setsid taskset -c "$WORKER_CPUS" env "PYTHONPATH=${WORKER_PYTHONPATH:-}" "$sglang/bin/python" -m dynamo.sglang \
            --model-path "$MODEL_PATH" --served-model-name "$MODEL" --page-size 16 --tp 1 --trust-remote-code \
            --disable-piecewise-cuda-graph $SGLANG_ARGS ${SGLANG_WORKER_ARGS:-} > "$RUN_DIR/worker.log" 2>&1 &
        echo $! > "$RUN_DIR/worker.pid"
        start_frontend
        wait_ready 1200 worker frontend ;;      # the first start loads the model and compiles kernels
    mock)
        port_free; rm -rf "$DYN_FILE_KV"
        setsid taskset -c "$WORKER_CPUS" env "PYTHONPATH=${WORKER_PYTHONPATH:-}" "$DYN_PY" -m dynamo.mocker \
            --model-path "$MODEL_PATH" --model-name "$MODEL" --extra-engine-args "${MOCKER_CONFIG:?}" \
            > "$RUN_DIR/worker.log" 2>&1 &
        echo $! > "$RUN_DIR/worker.pid"
        start_frontend
        wait_ready 120 worker frontend ;;
    frontend)
        port_free; start_frontend
        wait_ready 120 worker frontend ;;
    direct)
        port_free
        setsid taskset -c "$FRONTEND_CPUS,$WORKER_CPUS" "$sglang/bin/python" -m sglang.launch_server \
            --model-path "$MODEL_PATH" --served-model-name "$MODEL" --host 127.0.0.1 --port "$HTTP_PORT" --page-size 16 \
            --tp 1 --trust-remote-code --incremental-streaming-output --enable-metrics $SGLANG_ARGS > "$RUN_DIR/worker.log" 2>&1 &
        echo $! > "$RUN_DIR/worker.pid"
        wait_ready 1200 worker ;;
    stop)
        if [ "${2:-}" = frontend ]; then stop frontend; else stop frontend worker; rm -rf "$DYN_FILE_KV"; fi ;;
    *) sed -n '2,11p' "$0"; exit 1 ;;
esac
