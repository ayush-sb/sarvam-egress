#!/usr/bin/env bash
# The benchmark: SGLang's own server, the stock Dynamo frontend and the optimized frontend, same load.
#
#   ./bench.sh --quick --rounds 3   2048 streams, three CPU rounds per arm, medians (about 1 h): the recommended check
#   ./bench.sh --quick              2048 streams, one round (about 25 min; single windows vary by up to 10% on cloud VMs)
#   ./bench.sh                      256, 512, 1024 and 2048 streams, one CPU round per arm (about 1 h 45 min)
#   ./bench.sh --rounds 3           three CPU rounds per arm and level, reported as the median (all levels: about 2 h 30 min)
#   ./bench.sh --levels "512 2048"  other levels (2048 is required; 4096 is allowed)
#   ./bench.sh --resume DIR         continue a stopped run
#   ./bench.sh --mock ...           Dynamo's mock engine instead of SGLang, no GPU (needs ./setup.sh --mock);
#                                   stock and optimized arms only, no latency windows
#
# Needs ./setup.sh and benchmark mode (sudo ./bench-mode.sh on). Results: results/bench-<time>/table.md
set -euo pipefail
cd "$(dirname "$0")"
levels="256 512 1024 2048" rounds=1 out= mock=0
while (( $# )); do
    case $1 in
        --quick) levels=2048; shift ;;
        --levels) levels=$2; shift 2 ;;
        --rounds) rounds=$2; shift 2 ;;
        --resume) out=$(realpath "$2"); shift 2 ;;
        --mock) mock=1; shift ;;
        *) sed -n '2,13p' "$0"; exit 1 ;;
    esac
done
if [[ $mock == 1 ]]; then
    source config/mock.env
    export MOCK=1 MOCKER_CONFIG OUTPUT_TOKENS OUTPUT_SPREAD OPTIMIZED_WORKER_THREADS
    [[ -x loadgen/target/release/loadgen ]] || { echo "The load generator is not built: ./setup.sh --mock" >&2; exit 1; }
else
    source config/model.env
fi
export BUILD_DIR=$(realpath -m "${BUILD_DIR:-build}") MODEL MODEL_PATH SGLANG_ARGS SGLANG_WORKER_ARGS
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH
[[ -d /run/sarvam-bench-state ]] || { echo "Benchmark mode is off: sudo ./bench-mode.sh on" >&2; exit 1; }
ulimit -Sn 65536 2>/dev/null || ulimit -Sn "$(ulimit -Hn)"     # 2048 streams need many open files
if [[ -n $out ]]; then      # a resumed run keeps its own levels and rounds
    levels=$(sed -n 's/^levels=//p' "$out/config.txt"); rounds=$(sed -n 's/^rounds=//p' "$out/config.txt")
fi
out=${out:-$PWD/results/bench-$(date +%Y%m%d-%H%M%S)}
export LEVELS=$levels RUNS=$rounds LATENCY_RUNS=1 LATENCY_RUNS_2048=$(( rounds > 1 ? 2 : 1 ))
mkdir -p "$out"
if scripts/sweep.sh "$out" 2>&1 | tee -a "$out/bench.log"; then
    echo "Results: $out/table.md"
else
    echo "Stopped (the reason is above). A run that stopped part-way continues with: ./bench.sh --resume $out" >&2; exit 1
fi
