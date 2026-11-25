#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of cleanup-nightly.sh with a small fixture (no real time passing: -mmin is faked via touch -d). Run:
# kit/release/cleanup-nightly_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/cleanup-nightly.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-nightly-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

mk() { mkdir -p "$1"; echo data > "$1/f"; touch -d "$2" "$1"; }   # mk DIR DATE: a nightly dir, mtime set to DATE

# 1. An old nightly (10 days) is removed and recorded in nightly-done.txt; a young one (1 day) is kept.
root="$t/good"; mk "$root/nightly/2026-11-10-0300" "10 days ago"; mk "$root/nightly/2026-11-25-0300" "1 day ago"
out="$(env RELEASE_ROOT="$root" NIGHTLY_KEEP_DAYS=7 "$tool" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "cleanup runs"; else bad "cleanup failed: $out"; fi
if [ ! -e "$root/nightly/2026-11-10-0300" ] && [ -d "$root/nightly/2026-11-25-0300" ]; then ok "the old nightly is removed, the young one is kept"; else bad "wrong directory removed"; fi
if grep -qx '/nightly/2026-11-10-0300/' "$root/nightly-done.txt"; then ok "the removed nightly is recorded in nightly-done.txt"; else bad "exclude line missing"; fi

# 2. -n (dry run): nothing is removed, nothing is recorded.
root="$t/dry"; mk "$root/nightly/2026-11-01-0300" "20 days ago"
out="$(env RELEASE_ROOT="$root" NIGHTLY_KEEP_DAYS=7 "$tool" -n 2>&1)"
if echo "$out" | grep -q 'would remove'; then ok "-n reports what it would do"; else bad "-n produced no report: $out"; fi
if [ -d "$root/nightly/2026-11-01-0300" ] && [ ! -f "$root/nightly-done.txt" ]; then ok "-n changes nothing"; else bad "-n removed something"; fi

# 3. NIGHTLY_KEEP_DAYS=0: everything goes, regardless of age.
root="$t/zero"; mk "$root/nightly/2026-11-25-1200" "1 minute ago"
out="$(env RELEASE_ROOT="$root" NIGHTLY_KEEP_DAYS=0 "$tool" 2>&1)"
if [ ! -e "$root/nightly/2026-11-25-1200" ]; then ok "NIGHTLY_KEEP_DAYS=0 removes even a fresh nightly"; else bad "fresh nightly kept with KEEP_DAYS=0"; fi

# 4. A name that is not a date (someone's stray folder) is left alone.
root="$t/stray"; mkdir -p "$root/nightly/not-a-date"; touch -d "30 days ago" "$root/nightly/not-a-date"
out="$(env RELEASE_ROOT="$root" NIGHTLY_KEEP_DAYS=7 "$tool" 2>&1)"
if [ -d "$root/nightly/not-a-date" ]; then ok "a non-date directory name is left alone"; else bad "stray directory was removed"; fi

# 5. No nightly directory at all (before the first nightly pull): nothing to do, not an error.
out="$(env RELEASE_ROOT="$t/empty" "$tool" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'nothing to do'; then ok "a missing nightly directory is not an error"; else bad "missing nightly directory mishandled: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
