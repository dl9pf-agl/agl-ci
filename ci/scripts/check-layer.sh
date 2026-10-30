#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# yocto-check-layer on the layers that ci/build-matrix.yaml names (default: meta-agl-core). Own job in layer-ci.yml, once per
# workflow run, next to the build jobs: it runs against the bare _validate-base config, which has no machine, features or target,
# so it does not depend on a matrix entry. The tool's output goes straight to the job log; the exit status is the tool's.
set -euo pipefail
# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE"

# yocto-check-layer needs actual bitbake layer roots (dirs with their own conf/layer.conf) -
# ci/build-matrix.yaml's check_layers.layers names them exactly, so CHECK_LAYERS entries are
# used directly, no more searching for them. Paths are hardcoded to /work (kas-container's
# fixed mount point for the repo root - $KAS_WORK_DIR is NOT propagated into the
# bitbake-sourced shell env, confirmed empty there) since `kas shell -c` runs from
# /work/build, not the repo root. Runs against the bare _validate-base combo (no AGL layers
# pre-loaded) since yocto-check-layer manages its own layer-under-test additions and errors
# on duplicate BBFILE_COLLECTIONS otherwise.
#
# CHECK_LAYERS (space-separated paths matching ci/build-matrix.yaml's check_layers.layers; set in the
# environment: CHECK_LAYERS="..." ci/scripts/check-layer.sh) defaults to just meta-agl-core:
# checking every vendored sublayer is slow and most of them aren't what's actively being
# changed here. `CHECK_LAYERS=all` checks every curated layer. Each layer's dependencies
# (yocto-check-layer's --dependency/--additional-layers) come from
# ci/build-matrix.yaml's check_layers: key via _matrix.py - add a newly-vendored layer's
# dependency info there, not here.
# check_layers.default of a repo in scope adds its layers to the default; none does today (the layers of meta-agl-demo and
# meta-agl-devel are prepared but not yet checked by default, agl-ci chapter 13).
CHECK_LAYERS="${CHECK_LAYERS:-meta-agl/meta-agl-core $("$PY" "$ENGINE/_matrix.py" --default-check-layers | tr '\n' ' ')}"
if [ "$CHECK_LAYERS" = "all" ]; then
  CHECK_LAYERS="$("$PY" "$ENGINE/_matrix.py" --list-check-layers | tr '\n' ' ')"
fi
# shellcheck disable=SC2086
CHECK_LAYER_ARGS="$("$PY" "$ENGINE/_matrix.py" --check-layer-args $CHECK_LAYERS)"
CHECK_LAYER_PATHS=""
for l in $CHECK_LAYERS; do
  CHECK_LAYER_PATHS="$CHECK_LAYER_PATHS $AGL_WORKDIR/$l"
done
# dl-shared: this is the first bitbake run of a job, so it fetches the uninative tarball; without the shared
# downloads it lands in the throw-away build/downloads and never reaches the cache.
kas_run shell "build/ci-kas/_validate-base.yml:kas/pins.yml$(kas_dl_include)" -c "yocto-check-layer$CHECK_LAYER_PATHS $CHECK_LAYER_ARGS"
