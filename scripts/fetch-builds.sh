#!/usr/bin/env bash
# Download the published builds (config/release.env), check them against config/release.sha256,
# unpack them into BUILD_DIR and stage them for the benchmark. Called by ./setup.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
BUILD_DIR=$(realpath -m "${BUILD_DIR:-$ROOT/build}")
source config/release.env
[[ -s config/release.sha256 ]] || { echo "no published builds in config/release.sha256; use ./setup.sh --from-source" >&2; exit 1; }
mkdir -p "$BUILD_DIR/downloads"
cd "$BUILD_DIR/downloads"
for f in $RELEASE_FILES; do
    curl -fL --retry 3 -o "$f" "$RELEASE_URL/$f"
done
grep -F -f <(printf '%s\n' $RELEASE_FILES) "$ROOT/config/release.sha256" | sha256sum --quiet -c - \
    || { echo "a downloaded file does not match config/release.sha256" >&2; exit 1; }
cd "$BUILD_DIR"
for f in $RELEASE_FILES; do tar --zstd -xf "downloads/$f"; done
"$ROOT/scripts/stage-builds.sh" "downloaded release $RELEASE_TAG ($(cat release-info/built-on))"
