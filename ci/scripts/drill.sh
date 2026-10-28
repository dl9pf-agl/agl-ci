#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Outage drill: run the source fetch (or the whole build) of a matrix entry with the network switched off in bitbake
# and list every fetch that fails. Needs a warm DL_DIR (AGL_DL_DIR) or mirrors; kas itself still clones the layers.
#   drill.sh --machine M --features F --target T [--mode fetchall|build|mirror|mirror-build]
# fetchall: minutes, tests that every SRC_URI of the target is available. build: hours, also finds recipes that
# fetch inside do_compile (npm, pub, cargo, flutter); use an empty sstate dir so that every task really runs.
# mirror / mirror-build: the same two, but "from the mirror alone": an EMPTY private download and sstate directory
# (build/drill-cache, so nothing of the shared cache helps), AGL_MIRROR_URL required, and bitbake may talk only to the host of the
# mirror (BB_ALLOWED_NETWORKS; every other host fails as an untrusted URL). This is what a clean rebuild on a new builder during
# an upstream outage (tier T2) looks like. mirror = sources only, minutes; mirror-build = the whole build, sstate from the mirror too.
# (Not BB_FETCH_PREMIRRORONLY: with it a gitsm:// recipe cannot fetch its submodules from the mirror, tested 2026-10-27.)
set -uo pipefail

# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE" || exit 1

MODE=fetchall
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$MODE" in fetchall|build|mirror|mirror-build) ;; *) echo "drill.sh: --mode must be fetchall, build, mirror or mirror-build" >&2; exit 2 ;; esac
parse_common_args "${args[@]}"

case "$MODE" in
  mirror|mirror-build)
    [ -n "${AGL_MIRROR_URL:-}" ] || { echo "drill.sh: --mode $MODE needs AGL_MIRROR_URL (http(s) URL of the mirror)" >&2; exit 2; }
    # an empty, private cache inside the workspace, so that nothing of the shared cache can satisfy a fetch
    rm -rf "$TREE/build/drill-cache"; mkdir -p "$TREE/build/drill-cache/dl" "$TREE/build/drill-cache/sstate"
    export AGL_DL_DIR="$TREE/build/drill-cache/dl" AGL_SSTATE_DIR="$TREE/build/drill-cache/sstate"
    mirror_host="${AGL_MIRROR_URL#*://}"; mirror_host="${mirror_host%%/*}"; mirror_host="${mirror_host%%:*}"
    [[ "$mirror_host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "drill.sh: cannot read a host name from AGL_MIRROR_URL=$AGL_MIRROR_URL" >&2; exit 2; }
    printf 'header:\n  version: 23\nlocal_conf_header:\n  ci-allowed-networks: |\n    BB_ALLOWED_NETWORKS = "%s"\n' "$mirror_host" > "$TREE/build/ci-kas/ci-allowed-networks.yml"
    DRILL_KAS=build/ci-kas/ci-allowed-networks.yml; DRILL_WHAT="the mirror host $mirror_host only (BB_ALLOWED_NETWORKS)" ;;
  *)
    # The offline drill proves the local cache; with the network off a mirror URL could only produce misses.
    unset AGL_MIRROR_URL AGL_GIT_MIRROR KAS_PREMIRRORS
    DRILL_KAS=build/ci-kas/ci-offline.yml; DRILL_WHAT="BB_NO_NETWORK=1" ;;
esac

matrix_fields kasfiles,target
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes):$DRILL_KAS"
TARGET="${_MATRIX_FIELDS[1]}"
RESULTS_DIR="${RESULTS_DIR:-$TREE/build/drill-results}"
mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/$MODE.log"

echo "drill.sh: $MODE of $TARGET with $DRILL_WHAT ($KASFILES)"
if [ "$MODE" = fetchall ] || [ "$MODE" = mirror ]; then
  # -k: keep going, so that one run lists every miss, not only the first
  kas_run shell "$KASFILES" -c "bitbake -k --runall=fetch $TARGET" >"$LOG" 2>&1
else
  KAS_TARGET="$TARGET" kas_run build "$KASFILES" >"$LOG" 2>&1
fi
rc=$?

grep -E 'Network access disabled|NetworkAccess|Fetcher failure|Unable to fetch URL' "$LOG" | sort -u >"$RESULTS_DIR/misses.txt" || true
n="$(wc -l <"$RESULTS_DIR/misses.txt")"
echo "drill.sh: bitbake exit $rc, $n distinct fetch failures (see $RESULTS_DIR/misses.txt, log $LOG)"
[ "$rc" -eq 0 ] && [ "$n" -eq 0 ]
