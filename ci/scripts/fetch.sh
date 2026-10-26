#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fill the download cache: fetch every source of a matrix entry's target with the network on and write git mirror
# tarballs (BB_GENERATE_MIRROR_TARBALLS), so that DL_DIR (AGL_DL_DIR) can be published as a source mirror. Chapter 15.
#   fetch.sh --machine M --features F --target T
set -uo pipefail

# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE" || exit 1

parse_common_args "$@"

matrix_fields kasfiles,target
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes):build/ci-kas/ci-mirror.yml"
TARGET="${_MATRIX_FIELDS[1]}"
RESULTS_DIR="${RESULTS_DIR:-$TREE/build/fetch-results}"
mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/fetch.log"

echo "fetch.sh: fetch of $TARGET ($KASFILES)"
# -k: keep going, so that one run fetches everything it can
kas_run shell "$KASFILES" -c "bitbake -k --runall=fetch $TARGET" >"$LOG" 2>&1
rc=$?

tarballs="$(find "${AGL_DL_DIR:-$TREE/build/downloads}" -maxdepth 1 -name 'git2_*.tar.gz' | wc -l)"
echo "fetch.sh: bitbake exit $rc, $tarballs git mirror tarballs in ${AGL_DL_DIR:-DL_DIR} (log $LOG)"
exit "$rc"
