#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checks the "check helper" block of ci/scripts/validate.sh: quiet and --verbose output, PASSED/FAILED, exit status, annotations.
# Usage: ci/scripts/validate_test.sh [path-to-validate.sh]
set -u
f="${1:-$(dirname "$0")/validate.sh}"; fail=0; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
blk="$(sed -n '/^# --- begin check helper/,/^# --- end check helper/p' "$f")"
[ -n "$blk" ] || { echo "FAIL  no check helper block in $f" >&2; exit 1; }
# run VERBOSE NAME CMD...: runs the helper like validate.sh does (pipefail, no -e) and prints "status=<n>" last
run() { local v="$1"; shift; VERBOSE="$v" RESULTS_DIR="$t" bash -c 'set -uo pipefail; verbose=$VERBOSE; status=0; summary=()
'"$blk"'
run_host_check "$@"; printf "%s\n" "${summary[@]}"; echo "status=$status"' _ "$@" 2>&1; }
check() { local what="$1" out="$2" pat="$3" want="$4"; if grep -qE -- "$pat" <<<"$out"; then got=yes; else got=no; fi
  if [ "$got" = "$want" ]; then echo "ok    $what"; else echo "FAIL  $what (pattern '$pat' present: $got, want $want)"; fail=1; fi; }
q="$(run 0 okcheck bash -c 'echo hello-output')"
check "quiet: PASSED line"              "$q" "okcheck PASSED"                     yes
check "quiet: the check output is not printed" "$q" "hello-output"               no
check "quiet: no log group"             "$q" "::group::"                          no
check "quiet: output is in the log file" "$(cat "$t/okcheck.log")" "hello-output" yes
v="$(run 1 okcheck bash -c 'echo hello-output')"
check "verbose: output is printed"      "$v" "^hello-output"                      yes
check "verbose: log group opened and closed" "$v" "::group::validate.sh: okcheck"  yes
check "verbose: group is closed"        "$v" "::endgroup::"                       yes
check "verbose: command is shown"       "$v" "command: bash -c echo hello-output" yes
check "verbose: summary row with seconds" "$v" "okcheck +PASSED +[0-9]+s"         yes
check "verbose: status 0"               "$v" "status=0"                           yes
check "verbose: output is also in the log file" "$(cat "$t/okcheck.log")" "hello-output" yes
b="$(run 1 badcheck bash -c 'seq -f line-%g 1 60; echo boom-output; exit 3')"
check "verbose failure: tail repeated outside the group" "$b" "last 40 lines of badcheck"  yes
check "verbose failure: tail has the last line"  "$(sed -n '/last 40 lines/,$p' <<<"$b")" "boom-output"  yes
check "verbose failure: tail is cut at 40 lines" "$(sed -n '/last 40 lines/,$p' <<<"$b")" "line-1$"  no
check "verbose failure: output is printed" "$b" "^boom-output"                    yes
check "verbose failure: FAILED line"    "$b" "badcheck FAILED"                    yes
check "verbose failure: error annotation" "$b" "^::error title=validate.sh badcheck::" yes
check "verbose failure: status 1"       "$b" "status=1"                           yes
qb="$(run 0 badcheck bash -c 'echo boom-output; exit 3')"
check "quiet failure: status 1"         "$qb" "status=1"                          yes
check "quiet failure: no annotation"    "$qb" "::error"                           no
check "quiet failure: no tail"          "$qb" "last 40 lines"                     no
exit "$fail"
