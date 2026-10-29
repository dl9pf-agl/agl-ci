#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2016,SC2086,SC2015  # intentional in this test: the scripts under test are single-quoted and must not expand here,
#   $2 holds several VAR=value words, and the PASS/FAIL lines are not an if-then-else
# Checks the "settings restore" block of kit/deploy.sh: what a plain update keeps, what a given variable changes, and how the old limit
# names (MEM_LIMIT ...) become the RUNNER limits. Usage: kit/deploy_test.sh [path-to-deploy.sh]
set -u
f="${1:-$(dirname "$0")/deploy.sh}"; fail=0; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
blk="$(sed -n '/^# --- begin settings restore/,/^# --- end settings restore/p' "$f")"
[ -n "$blk" ] || { echo "FAIL  no settings restore block in $f" >&2; exit 1; }
# res STORED GIVEN -> prints the resulting limits. STORED is the content of the old runner.env, GIVEN the environment of the call.
res() { printf '%b' "$1" > "$t/runner.env"
  env -i PATH="$PATH" $2 ENVFILE="$t/runner.env" bash -c 'old() { sed -n "s/^$1=//p" "$ENVFILE"; }
'"$blk"'
echo "R=${MEM_LIMIT_RUNNER:-}/${CPU_LIMIT_RUNNER:-} S=${MEM_LIMIT_SIDECAR:-}/${CPU_LIMIT_SIDECAR:-} L=${LINT_MEM_LIMIT_RUNNER:-}/${LINT_CPU_LIMIT_RUNNER:-}/${LINT_MEM_LIMIT_SIDECAR:-}/${LINT_CPU_LIMIT_SIDECAR:-} SLOTS=${SLOTS:-}"'; }
expect() { local got; got="$(res "$2" "$3")"; if [ "$got" = "$4" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$got', want '$4'"; fail=1; fi; }
expect "old runner.env: MEM_LIMIT and CPU_LIMIT become the RUNNER values" "MEM_LIMIT=24g\nCPU_LIMIT=8\nLINT_MEM_LIMIT=4g\nLINT_CPU_LIMIT=2\nSLOTS=2\n" "" "R=24g/8 S=/ L=4g/2// SLOTS=2"
expect "new runner.env is kept by a plain update"        "MEM_LIMIT_RUNNER=6g\nCPU_LIMIT_RUNNER=3\nMEM_LIMIT_SIDECAR=20g\nCPU_LIMIT_SIDECAR=7\nLINT_MEM_LIMIT_SIDECAR=3g\nSLOTS=2\n" "" "R=6g/3 S=20g/7 L=//3g/ SLOTS=2"
expect "a given SIDECAR limit beats the stored one"      "MEM_LIMIT_SIDECAR=20g\nCPU_LIMIT_SIDECAR=7\n" "MEM_LIMIT_SIDECAR=28g" "R=/ S=28g/7 L=/// SLOTS="
expect "a given old name beats the stored new name"      "MEM_LIMIT_RUNNER=24g\n" "MEM_LIMIT=32g" "R=32g/ S=/ L=/// SLOTS="
expect "a given new name beats a given old name"         "" "MEM_LIMIT=32g MEM_LIMIT_RUNNER=16g" "R=16g/ S=/ L=/// SLOTS="
expect "stored new name beats stored old name"           "MEM_LIMIT=24g\nMEM_LIMIT_RUNNER=10g\n" "" "R=10g/ S=/ L=/// SLOTS="
expect "nothing stored, nothing given: stays empty (defaults come later)" "" "" "R=/ S=/ L=/// SLOTS="
exit "$fail"
