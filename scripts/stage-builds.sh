#!/usr/bin/env bash
# Lay out BUILD_DIR for the benchmark, from BUILD_DIR/vanilla and BUILD_DIR/optimized:
#   pristine -> vanilla (stock frontend), worker -> vanilla (the SGLang worker in every arm), optimized,
#   dynamo-commit, recipe, binaries.sha256, patches.sha256, provenance.txt; then import checks.
#   scripts/stage-builds.sh "PROVENANCE LINE"
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
BUILD_DIR=$(realpath -m "${BUILD_DIR:-$ROOT/build}")
for v in vanilla optimized; do
    [[ -s $BUILD_DIR/$v/dynamo/_core.abi3.so ]] || { echo "missing $BUILD_DIR/$v/dynamo/_core.abi3.so" >&2; exit 1; }
done
( cd "$BUILD_DIR"
  ln -sfn vanilla pristine; ln -sfn vanilla worker
  git -C "$ROOT" ls-tree HEAD dynamo | awk '{print $3}' > dynamo-commit
  echo final > recipe
  sha256sum {pristine,optimized,worker}/dynamo/_core.abi3.so > binaries.sha256
  printf '%s\n' "${1:?provenance line}" "vanilla $(cut -c1-16 <<< "$(sha256sum < vanilla/dynamo/_core.abi3.so)")" \
      "optimized $(cut -c1-16 <<< "$(sha256sum < optimized/dynamo/_core.abi3.so)")" > provenance.txt )
sha256sum patches/optimized/series patches/optimized/*.patch patches/instrumentation/* > "$BUILD_DIR/patches.sha256"
for v in pristine optimized; do
    PYTHONPATH=$BUILD_DIR/$v .venv/bin/python -c 'from dynamo import _core; import dynamo.frontend' \
        || { echo "the $v frontend does not import" >&2; exit 1; }
done
PYTHONPATH=$BUILD_DIR/worker .venv-sglang/bin/python -c 'from dynamo import _core; import dynamo.sglang' 2>/dev/null \
    || { echo "the Dynamo SGLang worker does not import" >&2; exit 1; }
