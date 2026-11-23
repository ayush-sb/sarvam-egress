#!/usr/bin/env bash
# Build one variant of Dynamo's native library, BUILD_DIR/<variant>/dynamo/_core.abi3.so:
#
#   scripts/build-dynamo.sh vanilla     Dynamo 1.6.2 as pinned, with Dynamo's own build settings
#   scripts/build-dynamo.sh train       patches/optimized, ThinLTO, instrumented for PGO training
#   scripts/build-dynamo.sh optimized   patches/optimized, ThinLTO + PGO (needs BUILD_DIR/pgo/merged.profdata)
#
# Each variant builds from a git worktree of dynamo/ at the pinned commit, so dynamo/ itself stays as it is.
# A PGO profile only fits code built from the same path: train and optimized share BUILD_DIR/src/optimized.
# The compiler output goes to BUILD_DIR/build-<variant>.log.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
variant=${1:?usage: scripts/build-dynamo.sh vanilla|train|optimized}
BUILD_DIR=$(realpath -m "${BUILD_DIR:-$ROOT/build}")
log() { echo "$(date +%T) $*" | tee -a "$BUILD_DIR/build.log"; }
mkdir -p "$BUILD_DIR/tmp" "$BUILD_DIR/$variant/dynamo"

# The source, prepared once: a worktree at the pin, with the patches for the optimized variants.
src=$BUILD_DIR/src/vanilla
[[ $variant == vanilla ]] || src=$BUILD_DIR/src/optimized
if [[ ! -e $src/.series-applied ]]; then
    rm -rf "$src"; git -C "$ROOT/dynamo" worktree prune
    git -C "$ROOT/dynamo" worktree add --detach "$src" "$(git -C "$ROOT" ls-tree HEAD dynamo | awk '{print $3}')" > /dev/null
    if [[ $variant != vanilla ]]; then
        for patch in $(cat "$ROOT/patches/optimized/series"); do git -C "$src" apply "$ROOT/patches/optimized/$patch"; done
    fi
    touch "$src/.series-applied"
fi

unset RUSTFLAGS
# A fixed PATH: one of Dynamo's crates rebuilds everything above it whenever PATH differs.
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
export CARGO_PROFILE_PROFILING_DEBUG=1          # line tables, for the flame graphs
if [[ $variant != vanilla ]]; then              # vanilla: Dynamo's .cargo/config.toml (x86-64-v3, frame pointers)
    export CARGO_PROFILE_PROFILING_LTO=thin RUSTFLAGS="-Ctarget-cpu=x86-64-v3 -Cforce-frame-pointers=yes --cfg tokio_unstable"
    if [[ $variant == train ]]; then
        RUSTFLAGS+=" -Cprofile-generate=$BUILD_DIR/pgo/raw"
    else
        # Each profile gets a name of its own (cargo notices a changed flag, not a changed file), and an
        # existing copy is left alone (a fresh timestamp alone would make the compiler start over).
        profile=$BUILD_DIR/pgo/use-$(sha256sum < "$BUILD_DIR/pgo/merged.profdata" | cut -c1-16).profdata
        [[ -e $profile ]] || cp "$BUILD_DIR/pgo/merged.profdata" "$profile"
        RUSTFLAGS+=" -Cprofile-use=$profile -Cllvm-args=-pgo-warn-missing-function"
    fi
fi
# One compile job per 4 GB of free memory (ThinLTO needs a lot), at most one per CPU.
jobs=$(awk -v cpus="$(nproc)" '/MemAvailable/ {j = int($2 / 4194304); print (j < 1 ? 1 : (j > cpus ? cpus : j))}' /proc/meminfo)

log "build $variant started ($jobs jobs)"
rm -rf "$BUILD_DIR/wheels/$variant"
( cd "$src/lib/bindings/python" && CARGO_TARGET_DIR=$BUILD_DIR/target-$variant CARGO_BUILD_JOBS=$jobs TMPDIR=$BUILD_DIR/tmp \
    "$ROOT/.venv/bin/maturin" build --target x86_64-unknown-linux-gnu --profile profiling --locked --auditwheel skip \
    --interpreter "$ROOT/.venv/bin/python" --out "$BUILD_DIR/wheels/$variant" -v > "$BUILD_DIR/build-$variant.log" 2>&1 ) \
    || { log "build $variant failed; see $BUILD_DIR/build-$variant.log"; exit 1; }

# Take the library out of the wheel; record its checksum and how many functions had no profile data.
"$ROOT/.venv/bin/python" - "$BUILD_DIR" "$variant" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
from zipfile import ZipFile
build, variant = Path(sys.argv[1]), sys.argv[2]
library = build / variant / "dynamo/_core.abi3.so"
with ZipFile(next((build / "wheels" / variant).glob("*.whl"))) as wheel, wheel.open("dynamo/_core.abi3.so") as s, library.open("wb") as t:
    shutil.copyfileobj(s, t)
missing = (build / f"build-{variant}.log").read_text(errors="replace").count("no profile data available for function")
with library.open("rb") as f:
    digest = hashlib.file_digest(f, "sha256").hexdigest()
(build / f"build-{variant}.json").write_text(json.dumps({"library": str(library), "missing_profile_diagnostics": missing,
    "sha256": digest}, indent=2) + "\n")
PY
# It must import. (An instrumented library writes a profile at exit; keep that one out of the training data.)
LLVM_PROFILE_FILE=$BUILD_DIR/tmp/import-%p.profraw PYTHONPATH=$BUILD_DIR/$variant "$ROOT/.venv/bin/python" -c 'from dynamo import _core; import dynamo.frontend'
rm -f "$BUILD_DIR"/tmp/import-*.profraw
missing=$(jq -r .missing_profile_diagnostics "$BUILD_DIR/build-$variant.json")
[[ $variant != optimized || $missing == 0 ]] || log "warning: $missing functions had no profile data (the profile does not fit this source)"
log "build $variant done"
