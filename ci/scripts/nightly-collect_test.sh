#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of nightly-collect.sh with a fixture that looks like a real bitbake deploy directory (no kas, no docker, no network).
# Run: ci/scripts/nightly-collect_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/nightly-collect.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/nightly-collect-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

M=qemux86-64
# mkdeploy TREE TARGET KERNEL-TEXT: a deploy directory for TARGET, same shape release-collect_test.sh uses.
mkdeploy() {
  local tree="$1" target="$2" kernel="$3" d="$1/build/tmp/deploy/images/$M"
  mkdir -p "$d/junk"
  local suffix
  for suffix in ext4.xz manifest spdx.json; do
    echo "$target $suffix" > "$d/$target-$M-20261123110250.$suffix"
    ln -s "$target-$M-20261123110250.$suffix" "$d/$target-$M.$suffix"
  done
  echo "$kernel" > "$d/bzImage--6.18.52-r0-$M-20261113184708.bin"
  ln -s "bzImage--6.18.52-r0-$M-20261113184708.bin" "$d/bzImage-$M.bin"
  ln -s "bzImage-$M.bin" "$d/bzImage"
  echo "another image" > "$d/other-image-$M.ext4.xz"
}
collect() {
  local tree="$1" target="$2"; shift 2
  env AGL_TREE="$tree" NIGHTLY_STAGING="$t/stage" NIGHTLY_DATE=2026-11-26-0300 NIGHTLY_RUN_ID=run1 "$@" \
    "$tool" --machine "$M" --target "$target" --repo meta-agl 2>&1
}

# 1. A normal collect: the image's files and the shared kernel land in the per-repo/machine layout.
mkdeploy "$t/tree1" agl-image-minimal kernel-A
out="$(collect "$t/tree1" agl-image-minimal)"; rc=$?
dest="$t/stage/.2026-11-26-0300.partial/meta-agl/$M/deploy/images/$M"
if [ "$rc" -eq 0 ]; then ok "a normal collect runs"; else bad "collect failed: $out"; fi
if [ -f "$dest/agl-image-minimal-$M.ext4.xz" ] && [ -f "$dest/bzImage-$M.bin" ]; then ok "the image's own file and the shared kernel are collected"; else bad "files missing in $dest"; fi
if [ ! -e "$dest/other-image-$M.ext4.xz" ] && [ ! -e "$dest/junk" ]; then ok "another image's file and a plain directory are not collected"; else bad "unwanted entries collected"; fi

# 2. trowl-report/ (ci/scripts/trowl-scan.sh), a whole directory: collected recursively.
mkdeploy "$t/tree2" agl-ivi-demo-flutter kernel-A
mkdir -p "$t/tree2/build/tmp/deploy/images/$M/trowl-report"
echo '<html></html>' > "$t/tree2/build/tmp/deploy/images/$M/trowl-report/index.html"
echo '{}' > "$t/tree2/build/tmp/deploy/images/$M/trowl-report/report.json"
out="$(collect "$t/tree2" agl-ivi-demo-flutter)"; rc=$?
dest2="$t/stage/.2026-11-26-0300.partial/meta-agl/$M/deploy/images/$M"
if [ -f "$dest2/trowl-report/index.html" ] && [ -f "$dest2/trowl-report/report.json" ]; then ok "trowl-report/ is collected recursively"; else bad "trowl-report/ missing: $out"; fi

# 3. A shared kernel file that disagrees with what is already collected: refused.
mkdeploy "$t/tree3" third-image kernel-B
out="$(collect "$t/tree3" third-image)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'disagree'; then ok "a different kernel in the same nightly is refused"; else bad "kernel conflict accepted: $out"; fi

# 4. A partial directory of ANOTHER run: refused.
mkdeploy "$t/tree4" agl-image-minimal kernel-A
out="$(collect "$t/tree4" agl-image-minimal NIGHTLY_RUN_ID=run2)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'belongs to run run1'; then ok "a partial directory of another run is refused"; else bad "foreign partial accepted: $out"; fi

# 5. The final directory already exists (finalize already ran): refused.
mkdir -p "$t/stage/2026-11-26-0400"
out="$(collect "$t/tree4" agl-image-minimal NIGHTLY_DATE=2026-11-26-0400)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already exists'; then ok "an already-finalized date is refused"; else bad "existing final dir accepted: $out"; fi

# 6. Missing input / bad names.
out="$(collect "$t/nowhere" agl-image-minimal NIGHTLY_DATE=2026-11-26-0500)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no deploy directory'; then ok "a missing deploy directory is refused"; else bad "missing deploy directory accepted"; fi
out="$(collect "$t/tree4" agl-image-minimal NIGHTLY_DATE=bad-date 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad NIGHTLY_DATE'; then ok "a bad date format is refused"; else bad "bad date accepted: $out"; fi
out="$("$tool" --machine '../x' --target t --repo meta-agl 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a path in the machine name is refused"; else bad "path in machine name accepted"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
