#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of build.sh's "trowl scan step" block, same technique as release-build_test.sh: the block is cut out of build.sh by
# its marker comments and run in a fresh bash, with the variables build.sh has at that point and a stub trowl-scan.sh - no
# kas, no real scan. Run: ci/scripts/trowl-build_test.sh      The temporary directory it makes is left in place (path
# printed); remove it yourself.
set -uo pipefail
f="${1:-$(dirname "$0")/build.sh}"
t="$(mktemp -d "${TMPDIR:-/tmp}/trowl-build-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

trowl_step="$(sed -n '/^# --- begin trowl scan step/,/^# --- end trowl scan step/p' "$f")"
[ -n "$trowl_step" ] || { echo "FAIL: the marker comments of the trowl scan step are missing in $f" >&2; exit 1; }

# A fake ENGINE directory with a stub trowl-scan.sh that just echoes its arguments (and can fail on demand).
mkengine() {
  local e="$1"; mkdir -p "$e"
  cat > "$e/trowl-scan.sh" <<'SH'
#!/usr/bin/env bash
echo "TROWL $*"
[ -z "${TROWL_SCAN_FAIL:-}" ] || exit 1
SH
  chmod +x "$e/trowl-scan.sh"
}

# run_trowl TREE ENGINE [VAR=value ...]: run the block in a clean environment; prints what the stub saw and build.sh's own stderr.
run_trowl() {
  local tree="$1" engine="$2"; shift 2
  env -i PATH="$PATH" "$@" bash -c '
    set -uo pipefail
    TARGET=agl-image-minimal; MACHINE=qemux86-64; ENGINE="'"$engine"'"; TREE="'"$tree"'"
    '"$trowl_step"'
  ' 2>&1
}

# 1. AGL_TROWL unset: the block does nothing.
tree="$t/off"; mkdir -p "$tree"; mkengine "$t/off-engine"
out="$(run_trowl "$tree" "$t/off-engine")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "AGL_TROWL unset runs the scanner never"; else bad "unexpected output with AGL_TROWL unset: rc=$rc out=$out"; fi

# 2. AGL_TROWL=1: trowl-scan.sh is called with the deploy dir, target and machine; a success is silent otherwise.
tree="$t/on"; mkdir -p "$tree"; mkengine "$t/on-engine"
out="$(run_trowl "$tree" "$t/on-engine" AGL_TROWL=1)"; rc=$?
want="TROWL --deploy-dir $tree/build/tmp/deploy/images/qemux86-64 --target agl-image-minimal --machine qemux86-64"
if [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then ok "AGL_TROWL=1 calls trowl-scan.sh with the right deploy dir, target, machine"; else bad "wrong call: $out"; fi

# 3. trowl-scan.sh fails: build.sh warns but the block itself does not fail (report-only).
tree="$t/fail"; mkdir -p "$tree"; mkengine "$t/fail-engine"
out="$(run_trowl "$tree" "$t/fail-engine" AGL_TROWL=1 TROWL_SCAN_FAIL=1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'WARNING: trowl scan failed'; then ok "a scan failure warns but does not fail the block"; else bad "scan failure not handled as report-only: rc=$rc out=$out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
