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

# fixture NAME RUN_ID: the directories as nightly-collect.sh leaves them: a public image and an empty work directory.
fixture() {
  local d="$t/$1/stage/2026-11-26-0300" p="$t/$1/stage/.2026-11-26-0300.partial"
  mkdir -p "$d/meta-agl/qemux86-64/img" "$p/meta-agl/qemux86-64"
  echo "image" > "$d/meta-agl/qemux86-64/img/img.ext4.xz"
  echo "${2:-run1}" > "$d/.run-id"; echo "${2:-run1}" > "$p/.run-id"
}
finalize() {
  local n="$1"; shift
  env NIGHTLY_STAGING="$t/$n/stage" NIGHTLY_DATE=2026-11-26-0300 NIGHTLY_RUN_ID=run1 "$@" "$tool" 2>&1
}

# 1. Good case: the marker is written, the empty work directory is gone, the image is untouched.
fixture good
out="$(finalize good)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$t/good/stage/2026-11-26-0300/COMPLETE" ]; then ok "a good nightly is marked complete"; else bad "good nightly refused: $out"; fi
if [ ! -e "$t/good/stage/.2026-11-26-0300.partial" ]; then ok "the empty work directory is removed"; else bad "work directory left"; fi
if [ -f "$t/good/stage/2026-11-26-0300/meta-agl/qemux86-64/img/img.ext4.xz" ]; then ok "the image is untouched"; else bad "image missing"; fi

# 2. A file left in the work directory (a collect that failed halfway) is reported and kept.
fixture leftover; echo x > "$t/leftover/stage/.2026-11-26-0300.partial/meta-agl/half.xz"
out="$(finalize leftover)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$t/leftover/stage/.2026-11-26-0300.partial/meta-agl/half.xz" ] && [ -f "$t/leftover/stage/.2026-11-26-0300.partial/.run-id" ] && echo "$out" | grep -q 'left over'; then ok "a leftover file is kept and reported"; else bad "leftover: $out"; fi

# 3. No nightly directory, and a second finalize: refused.
out="$(finalize missing)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no nightly directory'; then ok "a missing nightly directory is refused"; else bad "missing directory accepted: $out"; fi
out="$(finalize good)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already complete'; then ok "a second finalize is refused"; else bad "second finalize accepted: $out"; fi

# 4. The directory belongs to another run: refused, no marker.
fixture otherrun run2
out="$(finalize otherrun)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'does not carry run id run1' && [ ! -e "$t/otherrun/stage/2026-11-26-0300/COMPLETE" ]; then ok "a directory of another run is refused"; else bad "foreign run accepted: $out"; fi

# 5. Bad date format.
out="$(env NIGHTLY_STAGING="$t/bad/stage" NIGHTLY_DATE=bad NIGHTLY_RUN_ID=run1 "$tool" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad NIGHTLY_DATE'; then ok "a bad date format is refused"; else bad "bad date accepted: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
