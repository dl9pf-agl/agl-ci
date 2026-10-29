#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checks the "slot role" block of kit/run-loop.sh: slots 1..SLOTS keep the pool settings, the slots after them become lint slots.
# Usage: kit/run-loop_test.sh [path-to-run-loop.sh]
set -u
f="${1:-$(dirname "$0")/run-loop.sh}"; fail=0
blk="$(sed -n '/^# --- slot role/,/^# --- end slot role/p' "$f")"
[ -n "$blk" ] || { echo "FAIL  no slot role block in $f" >&2; exit 1; }
# role SLOT SLOTS -> prints "LABELS MEM CPU CACHE_DIR MIRROR HS_RW HS_UP"
role() { SLOT="$1" SLOTS="$2" bash -c 'slot=$SLOT; LABELS=agl-pr; MEM_LIMIT=24g; CPU_LIMIT=8; CACHE_DIR=/c; MIRROR_URL=http://m; HASHSERV_RW=h:1; HASHSERV_UPSTREAM=u:2
  LINT_LABELS=agl-lint; unset LINT_MEM_LIMIT LINT_CPU_LIMIT; '"$blk"'
echo "$LABELS $MEM_LIMIT $CPU_LIMIT [$CACHE_DIR] [$MIRROR_URL] [$HASHSERV_RW] [$HASHSERV_UPSTREAM]"'; }
expect() { local got; got="$(role "$2" "$3")"; if [ "$got" = "$4" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$got', want '$4'"; fail=1; fi; }
expect "slot 1 of 2 is a pool slot"          1 2 "agl-pr 24g 8 [/c] [http://m] [h:1] [u:2]"
expect "slot 2 of 2 is a pool slot"          2 2 "agl-pr 24g 8 [/c] [http://m] [h:1] [u:2]"
expect "slot 3 of 2 is a lint slot"          3 2 "agl-lint 4g 2 [] [] [] []"
expect "slot 2 of 1 is a lint slot"          2 1 "agl-lint 4g 2 [] [] [] []"
expect "slot 1 of 1 stays a pool slot"       1 1 "agl-pr 24g 8 [/c] [http://m] [h:1] [u:2]"
exit "$fail"
