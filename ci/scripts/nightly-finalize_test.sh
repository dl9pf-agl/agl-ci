#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of nightly-finalize.sh with a small fixture (no docker, no network). Run: ci/scripts/nightly-finalize_test.sh
# The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/nightly-finalize.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/nightly-finalize-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

# fixture NAME RUN_ID: a partial directory as nightly-collect.sh would leave it.
fixture() {
  local d="$t/$1/stage/.2026-11-26-0300.partial"
  mkdir -p "$d/meta-agl/qemux86-64/deploy/images/qemux86-64"
  echo "image" > "$d/meta-agl/qemux86-64/deploy/images/qemux86-64/img.ext4.xz"
  echo "${2:-run1}" > "$d/.run-id"
}
finalize() {
  local n="$1"; shift
  env NIGHTLY_STAGING="$t/$n/stage" NIGHTLY_DATE=2026-11-26-0300 NIGHTLY_RUN_ID=run1 "$@" "$tool" 2>&1
}

# 1. Good case: renamed, partial directory gone.
fixture good
out="$(finalize good)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a good nightly is finalized"; else bad "good nightly refused: $out"; fi
if [ -d "$t/good/stage/2026-11-26-0300" ] && [ ! -e "$t/good/stage/.2026-11-26-0300.partial" ]; then ok "the partial directory was renamed"; else bad "rename did not happen"; fi
if [ -f "$t/good/stage/2026-11-26-0300/meta-agl/qemux86-64/deploy/images/qemux86-64/img.ext4.xz" ]; then ok "the collected file is in the final directory"; else bad "file missing after rename"; fi

# 2. No partial directory: refused.
out="$(finalize missing)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no partial directory'; then ok "a missing partial directory is refused"; else bad "missing partial accepted: $out"; fi

# 3. The final directory already exists: refused, nothing touched.
fixture exists
mkdir -p "$t/exists/stage/2026-11-26-0300"
out="$(finalize exists)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already exists'; then ok "an existing final directory is refused"; else bad "existing final dir accepted: $out"; fi

# 4. The partial directory belongs to another run: refused.
fixture otherrun run2
out="$(finalize otherrun)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'does not carry run id run1'; then ok "a partial directory of another run is refused"; else bad "foreign partial accepted: $out"; fi

# 5. Bad date format.
out="$(env NIGHTLY_STAGING="$t/bad/stage" NIGHTLY_DATE=bad NIGHTLY_RUN_ID=run1 "$tool" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad NIGHTLY_DATE'; then ok "a bad date format is refused"; else bad "bad date accepted: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
