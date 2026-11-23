#!/usr/bin/env bash
# One-time setup on a fresh GPU machine: Ubuntu 24.04, one NVIDIA Blackwell GPU, about 150 GB of free disk.
#
#   ./setup.sh                 download the published builds (about 5-10 minutes, depending on download speeds)
#   ./setup.sh --from-source   build them here instead, with PGO training on this machine (about 45 minutes on the cloud machine)
#   ./setup.sh --mock          for ./bench.sh --mock: no GPU, no SGLang; the published builds, a small tokenizer and
#                              the Rust load generator (about 5 minutes)
#
# Then: sudo ./bench-mode.sh on && ./bench.sh
# The output of every command goes to build/setup.log. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")"
mode=${1:-}
[[ -z $mode || $mode == --from-source || $mode == --mock ]] || { sed -n '2,10p' "$0"; exit 1; }
if [[ $mode == --mock ]]; then source config/mock.env; else source config/model.env; fi
export BUILD_DIR=$(realpath -m "${BUILD_DIR:-build}")
mkdir -p "$BUILD_DIR"
exec 3>&1 >> "$BUILD_DIR/setup.log" 2>&1        # commands write to the log, progress lines to the screen
step() { echo "== $*" >&3; echo "== $(date +%T) $*"; }
trap 'echo "Setup failed. Last lines of $BUILD_DIR/setup.log:" >&3; tail -20 "$BUILD_DIR/setup.log" >&3' ERR

if [[ ${SKIP_SYSTEM:-0} != 1 ]]; then           # SKIP_SYSTEM=1: skip the GPU check and apt (for testing elsewhere)
    if [[ $mode == --mock ]]; then
        step "Checking the disk"
        (( $(df -Pk "$BUILD_DIR" | awk 'END {print $4}') > 20 * 1024 * 1024 )) \
            || { echo "This needs about 20 GB of free disk under $BUILD_DIR." >&3; exit 1; }
    else
        step "Checking the GPU and the disk"
        gpu=$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader | head -1); echo "   $gpu" >&3
        [[ $gpu =~ ,\ 1[0-9]\. ]] || { echo "This needs a Blackwell GPU (compute capability 10 or newer)." >&3; exit 1; }
        (( $(df -Pk "$BUILD_DIR" | awk 'END {print $4}') > 150 * 1024 * 1024 )) \
            || { echo "This needs about 150 GB of free disk under $BUILD_DIR." >&3; exit 1; }
    fi

    step "Installing system packages (sudo)"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential pkg-config cmake git curl jq zstd rsync \
        clang libclang-dev libssl-dev protobuf-compiler liburing-dev libjemalloc2 sysstat tcpdump libcap2-bin \
        linux-tools-common "linux-tools-$(uname -r)"
    sudo setcap cap_net_raw,cap_net_admin=eip "$(command -v tcpdump)"     # the benchmark captures packets as this user
fi

step "Installing Rust (for the flame-graph tool and the builds) and uv"
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH
command -v rustup || curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
rustup toolchain install "$(awk -F'"' '/channel/ {print $2}' rust-toolchain.toml)" --profile minimal --component llvm-tools-preview
command -v inferno-flamegraph || cargo install inferno --version 0.12.8 --locked
command -v uv || curl -LsSf https://astral.sh/uv/0.9.18/install.sh | sh

step "Fetching Dynamo 1.6.2 and adding the benchmark timestamps"
git submodule update --init dynamo
# The patches go on in order, so the last one tells whether they are already on.
last=$(ls patches/instrumentation/0*.patch | tail -1)
if ! git -C dynamo apply --reverse --check "../$last"; then
    for p in patches/instrumentation/0*.patch; do git -C dynamo apply "../$p"; done
fi

if [[ $mode == --mock ]]; then
    step "Creating the Python environment for the Dynamo frontend and its mock engine"
    uv python install 3.12.12
    uv sync --locked --inexact --no-install-package ai-dynamo-runtime
    # Dynamo's Python code comes from dynamo/; its native library comes from build/ (bench.sh sets PYTHONPATH).
    echo "$PWD/dynamo/lib/bindings/python/src" > .venv/lib/python3.12/site-packages/ai_dynamo_runtime.pth
    # Frontend 3 cores, mock engine 1 (one core keeps up with 2048 streams at a 50 ms step), client 2.
    [[ -f config/cpus.local.sh ]] || scripts/detect-cpus.py --worker 1

    step "Downloading the tokenizer (no model weights) and building the load generator"
    .venv/bin/hf download "$MODEL" --revision "$MODEL_REVISION" --include "*.json" --include "*.txt"
    cargo build --release --locked --manifest-path loadgen/Cargo.toml

    step "Downloading the published builds"
    scripts/fetch-builds.sh
    sed 's/^/   /' "$BUILD_DIR/provenance.txt" >&3
    echo "Setup complete. Next: sudo ./bench-mode.sh on, then ./bench.sh --mock" >&3
    exit 0
fi

step "Creating the Python environments: the Dynamo frontend, and SGLang 0.5.21 with the Dynamo worker"
uv python install 3.12.12
uv sync --locked --inexact --no-install-package ai-dynamo-runtime
[[ -x .venv-sglang/bin/python ]] || uv venv --python 3.12.12 .venv-sglang
uv pip sync --python .venv-sglang/bin/python config/sglang-linux-x86_64.txt
# Dynamo's Python code comes from dynamo/; its native library comes from build/ (bench.sh sets PYTHONPATH).
echo "$PWD/dynamo/lib/bindings/python/src" > .venv/lib/python3.12/site-packages/ai_dynamo_runtime.pth
sp=.venv-sglang/lib/python3.12/site-packages
echo "$PWD/dynamo/lib/bindings/python/src" > $sp/ai_dynamo_runtime.pth
echo "$PWD/dynamo/components/src" > $sp/ai_dynamo_components.pth
ln -sfn lib $sp/nvidia/cu13/lib64; ln -sfn libcudart.so.13 $sp/nvidia/cu13/lib/libcudart.so   # SGLang wants a CUDA toolkit layout
# Per-token arrival times in SGLang's benchmark client (skipped when the patch is already on).
patch -s -N -R --dry-run -p1 -d $sp < patches/instrumentation/sglang-0.5.21-benchmark.diff > /dev/null \
    || patch -s -N -p1 -d $sp < patches/instrumentation/sglang-0.5.21-benchmark.diff
.venv-sglang/bin/python -c 'import torch; assert torch.cuda.is_available(), "PyTorch cannot see the GPU"'
[[ -f config/cpus.local.sh ]] || scripts/detect-cpus.py              # which cores the frontend, worker and client get

step "Downloading the model in the background, and unpacking the prompt set"
.venv-sglang/bin/hf download "$MODEL" --revision "$MODEL_REVISION" &
model_download=$!
zstd -d -q -f config/workload/sharegpt-short.json.zst

if [[ $mode == --from-source ]]; then
    step "Building stock Dynamo and the optimized frontend, with PGO training (about 40 minutes)"
    scripts/build-dynamo.sh vanilla
    scripts/build-dynamo.sh train                                # optimized source, instrumented for PGO
    wait "$model_download"                                       # training serves the model
    [[ -s $BUILD_DIR/pgo/merged.profdata ]] || scripts/train-pgo.sh
    scripts/build-dynamo.sh optimized                            # ThinLTO + PGO with that profile
    scripts/stage-builds.sh "built on $(hostname) on $(date -I), PGO profile $(sha256sum < "$BUILD_DIR/pgo/merged.profdata" | cut -c1-16)"
else
    step "Downloading the published builds"
    scripts/fetch-builds.sh
    wait "$model_download"
fi
sed 's/^/   /' "$BUILD_DIR/provenance.txt" >&3
echo "Setup complete. Next: sudo ./bench-mode.sh on, then ./bench.sh" >&3
