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

# The fill reads from the real upstreams, never from a mirror (a stale mirror must not hide an upstream change, chapter 15).
# The one exception are the layer clones of kas: with AGL_GIT_MIRROR the host's git mirror (refreshed every 30 minutes from the
# upstreams, chapter 15) serves them, since git.yoctoproject.org and GitHub drop or throttle the 13 parallel clones of a nightly.
# A layer revision newer than the mirror makes the clone fail visibly and the next nightly passes.
unset KAS_PREMIRRORS
if [ -n "${AGL_GIT_MIRROR:-}" ] && [ -n "${AGL_MIRROR_URL:-}" ]; then
  AGL_MIRROR_URL="${AGL_MIRROR_URL%/}"; KAS_PREMIRRORS="$(agl_premirrors)" || exit 1; export KAS_PREMIRRORS
fi
unset AGL_MIRROR_URL AGL_GIT_MIRROR AGL_HASHSERV_RW AGL_HASHSERV_UPSTREAM   # the fill must not write equivalences either

matrix_fields kasfiles,target
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes):build/ci-kas/ci-mirror.yml"
TARGET="${_MATRIX_FIELDS[1]}"
RESULTS_DIR="${RESULTS_DIR:-$TREE/build/fetch-results}"
mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/fetch.log"

echo "fetch.sh: fetch of $TARGET ($KASFILES)"
# -k: keep going, so that one run fetches everything it can.
# The uninative tarball is no recipe source: bitbake's uninative handler downloads it into DL_DIR/uninative/<sha256>/ at the start of
# the first run. A mirror without it cannot rebuild anything on a new builder (chapter 15), so a fill that did not leave one behind
# fails instead of staying green. The check runs in the same container as the fetch: the runner container cannot enter CACHE_DIR
# (root:root 0700, kit/deploy.sh).
kas_run shell "$KASFILES" -c "bitbake -k --runall=fetch $TARGET; rc=\$?
  ls \"\${AGL_DL_DIR:-downloads}\"/uninative/*/*.tar.xz >/dev/null 2>&1 || { echo 'fetch.sh: ERROR: no uninative tarball in DL_DIR/uninative; the mirror would be incomplete' >&2; rc=1; }
  exit \$rc" >"$LOG" 2>&1
rc=$?
echo "fetch.sh: exit $rc, end of $LOG:"; tail -n 3 "$LOG"
exit "$rc"
