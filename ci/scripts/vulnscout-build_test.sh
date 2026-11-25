#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of build.sh's "vulnscout step" block, same technique as trowl-build_test.sh: the block is cut out of build.sh by
# its marker comments and run in a fresh bash, with a stub vulnscout-scan.sh - no real docker, no real scan.
# Run: ci/scripts/vulnscout-build_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
f="${1:-$(dirname "$0")/build.sh}"
t="$(mktemp -d "${TMPDIR:-/tmp}/vulnscout-build-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

step="$(sed -n '/^# --- begin vulnscout step/,/^# --- end vulnscout step/p' "$f")"
[ -n "$step" ] || { echo "FAIL: the marker comments of the vulnscout step are missing in $f" >&2; exit 1; }

# A fake ENGINE directory with a stub vulnscout-scan.sh that just echoes its arguments (and can fail on demand).
mkengine() {
  local e="$1"; mkdir -p "$e"
  cat > "$e/vulnscout-scan.sh" <<'SH'
#!/usr/bin/env bash
echo "VULNSCOUT $*"
[ -z "${VULNSCOUT_SCAN_FAIL:-}" ] || exit 1
SH
  chmod +x "$e/vulnscout-scan.sh"
}

# run TREE ENGINE [extra env assignments...]: run the block in a clean environment; prints what the stub saw and
# build.sh's own stderr.
run() {
  local tree="$1" engine="$2"; shift 2
  env -i PATH="$PATH" "$@" bash -c '
    set -uo pipefail
    TARGET=agl-image-minimal; MACHINE=qemux86-64; ENGINE="'"$engine"'"; TREE="'"$tree"'"
    '"$step"'
  ' 2>&1
}

# 1. AGL_VULNSCOUT unset: the block does nothing.
tree="$t/off"; mkdir -p "$tree"; mkengine "$t/off-engine"
out="$(run "$tree" "$t/off-engine")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "AGL_VULNSCOUT unset never runs the scan"; else bad "unexpected output with AGL_VULNSCOUT unset: rc=$rc out=$out"; fi

# 2. AGL_VULNSCOUT=1, a clean run: vulnscout-scan.sh is called with the deploy dir, target and machine; no warning.
tree="$t/on"; mkdir -p "$tree"; mkengine "$t/on-engine"
out="$(run "$tree" "$t/on-engine" AGL_VULNSCOUT=1)"; rc=$?
want="VULNSCOUT --deploy-dir $tree/build/tmp/deploy/images/qemux86-64 --target agl-image-minimal --machine qemux86-64"
if [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then ok "AGL_VULNSCOUT=1 calls vulnscout-scan.sh with the right deploy dir, target, machine"; else bad "wrong call: $out"; fi

# 3. A failure (tool error or a matched bar) without AGL_VULNSCOUT_ENFORCE: warns, the block itself does not fail.
tree="$t/fail"; mkdir -p "$tree"; mkengine "$t/fail-engine"
out="$(run "$tree" "$t/fail-engine" AGL_VULNSCOUT=1 VULNSCOUT_SCAN_FAIL=1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'WARNING: vulnscout scan failed or its bar matched'; then
  ok "a failure without AGL_VULNSCOUT_ENFORCE warns and does not fail the block"
else bad "report-only failure not handled: rc=$rc out=$out"; fi

# 4. The same failure WITH AGL_VULNSCOUT_ENFORCE=1: the block fails.
tree="$t/enforce"; mkdir -p "$tree"; mkengine "$t/enforce-engine"
out="$(run "$tree" "$t/enforce-engine" AGL_VULNSCOUT=1 VULNSCOUT_SCAN_FAIL=1 AGL_VULNSCOUT_ENFORCE=1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'AGL_VULNSCOUT_ENFORCE=1: failing the build'; then
  ok "AGL_VULNSCOUT_ENFORCE=1 lets the failure fail the block"
else bad "enforced failure not propagated: rc=$rc out=$out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
