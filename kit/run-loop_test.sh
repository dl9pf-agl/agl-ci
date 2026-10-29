#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2016,SC2086,SC2015  # intentional in this test: the scripts under test are single-quoted and must not expand here,
#   $2 holds several VAR=value words, and the PASS/FAIL lines are not an if-then-else
# Checks the "slot role" block of kit/run-loop.sh: slots 1..SLOTS keep the pool settings, the slots after them become lint slots, and the
# limits of the runner container and of the Docker sidecar (options of the sidecar's docker run) come out right.
# Usage: kit/run-loop_test.sh [path-to-run-loop.sh]
set -u
f="${1:-$(dirname "$0")/run-loop.sh}"; fail=0
blk="$(sed -n '/^# --- slot role/,/^# --- end slot role/p' "$f")"
[ -n "$blk" ] || { echo "FAIL  no slot role block in $f" >&2; exit 1; }
# role SLOT SLOTS [VAR=value ...] -> "LABELS runner:MEM/CPU sidecar-options [CACHE] [MIRROR] [HS_RW] [HS_UP]"
role() { local s="$1" n="$2"; shift 2; env -i PATH="$PATH" SLOT="$s" SLOTS="$n" "$@" bash -c 'slot=$SLOT; LABELS=agl-pr; CACHE_DIR=/c; MIRROR_URL=http://m; HASHSERV_RW=h:1; HASHSERV_UPSTREAM=u:2
  LINT_LABELS=agl-lint
'"$blk"'
echo "$LABELS $MEM_LIMIT_RUNNER/$CPU_LIMIT_RUNNER [${sc_limits[*]}] [$CACHE_DIR] [$MIRROR_URL] [$HASHSERV_RW] [$HASHSERV_UPSTREAM]"'; }
expect() { local what="$1" want="$2" got; shift 2; got="$(role "$@")"; if [ "$got" = "$want" ]; then echo "ok    $what"; else echo "FAIL  $what: got '$got', want '$want'"; fail=1; fi; }
pool="agl-pr 24g/8 [] [/c] [http://m] [h:1] [u:2]"
expect "slot 1 of 2: pool slot, runner 24g/8, sidecar unlimited"  "$pool"  1 2
expect "slot 2 of 2: pool slot"                                   "$pool"  2 2
expect "slot 1 of 1 stays a pool slot"                            "$pool"  1 1
expect "slot 3 of 2: lint slot, runner 4g/2, sidecar 2g/2, no cache" "agl-lint 4g/2 [--memory 2g --cpus 2] [] [] [] []"  3 2
expect "slot 2 of 1: lint slot"                                   "agl-lint 4g/2 [--memory 2g --cpus 2] [] [] [] []"  2 1
expect "sidecar limits given for a pool slot become docker options" "agl-pr 24g/8 [--memory 28g --cpus 7] [/c] [http://m] [h:1] [u:2]"  1 2 MEM_LIMIT_SIDECAR=28g CPU_LIMIT_SIDECAR=7
expect "only a memory limit for the sidecar"                      "agl-pr 24g/8 [--memory 28g] [/c] [http://m] [h:1] [u:2]"  1 2 MEM_LIMIT_SIDECAR=28g
expect "runner limits given"                                      "agl-pr 6g/3 [] [/c] [http://m] [h:1] [u:2]"  1 2 MEM_LIMIT_RUNNER=6g CPU_LIMIT_RUNNER=3
expect "old names MEM_LIMIT / CPU_LIMIT still bound the runner"   "agl-pr 32g/12 [] [/c] [http://m] [h:1] [u:2]"  1 2 MEM_LIMIT=32g CPU_LIMIT=12
expect "the pool sidecar limits do not leak into a lint slot"     "agl-lint 4g/2 [--memory 2g --cpus 2] [] [] [] []"  3 2 MEM_LIMIT_SIDECAR=28g CPU_LIMIT_SIDECAR=7
expect "lint slot limits given"                                   "agl-lint 1g/1 [--memory 3g --cpus 1] [] [] [] []"  3 2 LINT_MEM_LIMIT_RUNNER=1g LINT_CPU_LIMIT_RUNNER=1 LINT_MEM_LIMIT_SIDECAR=3g LINT_CPU_LIMIT_SIDECAR=1
expect "old lint names LINT_MEM_LIMIT / LINT_CPU_LIMIT still bound the lint runner" "agl-lint 8g/4 [--memory 2g --cpus 2] [] [] [] []"  3 2 LINT_MEM_LIMIT=8g LINT_CPU_LIMIT=4
# the options must really reach the two docker run calls: the sidecar gets sc_limits, the runner container gets the RUNNER limits
grep -qF '"agl-d$slot" --network "agl-n$slot" "${dev[@]}" "${sc_limits[@]}"' "$f" && echo "ok    the sidecar docker run gets the sidecar limits" || { echo "FAIL  the sidecar docker run does not use sc_limits"; fail=1; }
grep -qF -- '--memory "$MEM_LIMIT_RUNNER" --cpus "$CPU_LIMIT_RUNNER"' "$f" && echo "ok    the runner docker run gets the runner limits" || { echo "FAIL  the runner docker run does not use the RUNNER limits"; fail=1; }
exit "$fail"
