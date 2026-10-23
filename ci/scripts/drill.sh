#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Outage drill: run the source fetch (or the whole build) of a matrix entry with the network switched off in bitbake
# and list every fetch that fails. Needs a warm DL_DIR (AGL_DL_DIR) or mirrors; kas itself still clones the layers.
#   drill.sh --machine M --features F --target T [--mode fetchall|build]
# fetchall: minutes, tests that every SRC_URI of the target is available. build: hours, also finds recipes that
# fetch inside do_compile (npm, pub, cargo, flutter); use an empty sstate dir so that every task really runs.
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
case "$MODE" in fetchall|build) ;; *) echo "drill.sh: --mode must be fetchall or build" >&2; exit 2 ;; esac
parse_common_args "${args[@]}"

matrix_fields kasfiles,target
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes):build/ci-kas/ci-offline.yml"
TARGET="${_MATRIX_FIELDS[1]}"
RESULTS_DIR="${RESULTS_DIR:-$TREE/build/drill-results}"
mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/$MODE.log"

echo "drill.sh: $MODE of $TARGET with BB_NO_NETWORK=1 ($KASFILES)"
if [ "$MODE" = fetchall ]; then
  # -k: keep going, so that one run lists every miss, not only the first
  kas_run shell "$KASFILES" -c "bitbake -k -c fetchall $TARGET" >"$LOG" 2>&1
else
  KAS_TARGET="$TARGET" kas_run build "$KASFILES" >"$LOG" 2>&1
fi
rc=$?

grep -E 'Network access disabled|NetworkAccess|Fetcher failure|Unable to fetch URL' "$LOG" | sort -u >"$RESULTS_DIR/misses.txt" || true
n="$(wc -l <"$RESULTS_DIR/misses.txt")"
echo "drill.sh: bitbake exit $rc, $n distinct fetch failures (see $RESULTS_DIR/misses.txt, log $LOG)"
[ "$rc" -eq 0 ] && [ "$n" -eq 0 ]
