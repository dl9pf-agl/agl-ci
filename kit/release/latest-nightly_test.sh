#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of latest-nightly.sh on a small fake tree (no root, no network). Run: kit/release/latest-nightly_test.sh
# The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
tool="$(cd "$(dirname "$0")" && pwd)/latest-nightly.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/latest-nightly-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
n="$t/nightly"
image() { mkdir -p "$n/$1/meta-agl/qemux86-64/img"; : > "$n/$1/meta-agl/qemux86-64/img/img.SHA256SUMS"; }
run() { RELEASE_ROOT="$t" "$tool" 2>&1; }
points() { [ "$(readlink "$n/latest")" = "$1" ]; }

out="$(run)"; rc=$?; if [ "$rc" = 0 ] && [ ! -e "$n" ]; then ok "no nightly folder: nothing happens"; else bad "empty tree: $out"; fi
mkdir -p "$n"; out="$(run)"; if [ ! -L "$n/latest" ]; then ok "no nightly yet: no link"; else bad "link without a nightly"; fi
image 2026-11-25-2100; image 2026-11-26-0900; out="$(run)"
if points 2026-11-26-0900 && [ -f "$n/latest/meta-agl/qemux86-64/img/img.SHA256SUMS" ]; then ok "the link names the newest nightly and works"; else bad "newest: $out"; fi
mkdir -p "$n/2026-11-26-1200/meta-agl/qemux86-64/img" "$n/zzz-other"; : > "$n/nightly-notes"; run > /dev/null
if points 2026-11-26-0900; then ok "a nightly without a finished image and foreign names do not count"; else bad "took an empty one: $(readlink "$n/latest")"; fi
: > "$n/2026-11-26-1200/meta-agl/qemux86-64/img/img.SHA256SUMS"; run > /dev/null
if points 2026-11-26-1200 && [ ! -e "$n/.latest.tmp" ] && [ ! -e "$n/2026-11-26-0900/2026-11-26-1200" ]; then ok "the first image of a new run moves the link"; else bad "link not moved cleanly"; fi
out="$(run)"; if [ -z "$out" ]; then ok "nothing to change: silent"; else bad "second run: $out"; fi
mv "$n/2026-11-26-1200" "$t/gone"; run > /dev/null
if points 2026-11-26-0900; then ok "the newest was removed: the link goes back, never dead"; else bad "dead link: $(readlink "$n/latest")"; fi
mv "$n/2026-11-26-0900" "$t/gone2"; mv "$n/2026-11-25-2100" "$t/gone3"; run > /dev/null
if [ ! -L "$n/latest" ]; then ok "no image left: the link is removed"; else bad "link left over"; fi
mkdir "$n/latest"; out="$(run)"; rc=$?
if [ "$rc" != 0 ] && [ -d "$n/latest" ]; then ok "a real directory named latest is left alone"; else bad "replaced a directory: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
