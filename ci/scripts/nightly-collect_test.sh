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
C=0123456789012345678901234567890123456789
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
  env AGL_TREE="$tree" NIGHTLY_STAGING="$t/stage" NIGHTLY_DATE=2026-11-26-0300 NIGHTLY_RUN_ID=run1 NIGHTLY_COMMIT="$C" \
    NIGHTLY_RUN_URL=https://example.org/actions/runs/1 NIGHTLY_BUILDER=example.org/builder@sha256:abc "$@" \
    "$tool" --machine "$M" --target "$target" --repo meta-agl 2>&1
}

# 1. A normal collect: one public folder per image, complete, with build.toml and the sums file.
mkdeploy "$t/tree1" agl-image-minimal kernel-A
out="$(collect "$t/tree1" agl-image-minimal)"; rc=$?
run="$t/stage/2026-11-26-0300"
dest="$run/meta-agl/$M/agl-image-minimal"
if [ "$rc" -eq 0 ]; then ok "a normal collect runs"; else bad "collect failed: $out"; fi
if [ -f "$dest/agl-image-minimal-$M.ext4.xz" ] && [ ! -L "$dest/agl-image-minimal-$M.ext4.xz" ] && [ -f "$dest/bzImage-$M.bin" ]; then ok "the image's own file and the kernel are public at once"; else bad "files missing in $dest"; fi
if [ ! -e "$dest/other-image-$M.ext4.xz" ] && [ ! -e "$dest/junk" ]; then ok "another image's file and a plain directory are not collected"; else bad "unwanted entries collected"; fi
if grep -qx 'repo = "meta-agl"' "$dest/build.toml" && grep -qx "commit = \"$C\"" "$dest/build.toml" && grep -qx 'run = "https://example.org/actions/runs/1"' "$dest/build.toml"; then ok "build.toml names repo, commit and run"; else bad "build.toml wrong"; fi
if grep -qx 'builder = "example.org/builder@sha256:abc"' "$dest/build.toml"; then ok "build.toml names the builder image"; else bad "builder missing in build.toml"; fi
if (cd "$dest" && sha256sum -c --quiet agl-image-minimal.SHA256SUMS >/dev/null 2>&1) && grep -q ' build.toml$' "$dest/agl-image-minimal.SHA256SUMS" && ! grep -q 'SHA256SUMS' "$dest/agl-image-minimal.SHA256SUMS"; then ok "the sums file verifies, lists build.toml and not itself"; else bad "sums file wrong"; fi
if [ -z "$(find "$t/stage/.2026-11-26-0300.partial" -name '*.xz')" ] && [ ! -e "$run/COMPLETE" ]; then ok "nothing is left in the work directory and the run is not marked complete"; else bad "work files left, or COMPLETE written"; fi

# 2. A second image of the same machine with a DIFFERENT kernel and both scanner reports: its own folder, its own kernel.
mkdeploy "$t/tree2" agl-ivi-demo-flutter kernel-B
d2="$t/tree2/build/tmp/deploy/images/$M"
mkdir -p "$d2/report-trowl" "$d2/report-vulnscout"
echo '<html></html>' > "$d2/report-trowl/index.html"; echo 'summary' > "$d2/report-vulnscout/summary.adoc"
out="$(collect "$t/tree2" agl-ivi-demo-flutter)"; rc=$?
dest2="$run/meta-agl/$M/agl-ivi-demo-flutter"
if [ "$rc" -eq 0 ] && grep -qx kernel-B "$dest2/bzImage-$M.bin" && grep -qx kernel-A "$dest/bzImage-$M.bin"; then ok "two images of one machine keep their own kernel"; else bad "second image: $out"; fi
if [ -f "$dest2/report-trowl/index.html" ] && grep -q ' report-vulnscout/summary.adoc$' "$dest2/agl-ivi-demo-flutter.SHA256SUMS"; then ok "the scanner reports are collected and listed"; else bad "reports missing: $out"; fi

# 3. The same image twice in one run: refused.
out="$(collect "$t/tree1" agl-image-minimal)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already in the nightly'; then ok "the same image twice is refused"; else bad "duplicate accepted: $out"; fi

# 4. A directory of ANOTHER run: refused.
mkdeploy "$t/tree4" third-image kernel-A
out="$(collect "$t/tree4" third-image NIGHTLY_RUN_ID=run2)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'belongs to run run1'; then ok "a directory of another run is refused"; else bad "foreign run accepted: $out"; fi

# 5. A complete nightly: refused.
mkdir -p "$t/stage/2026-11-26-0400"; : > "$t/stage/2026-11-26-0400/COMPLETE"
out="$(collect "$t/tree4" third-image NIGHTLY_DATE=2026-11-26-0400)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already complete'; then ok "a complete nightly is refused"; else bad "complete nightly accepted: $out"; fi

# 6. Missing input / bad names.
out="$(collect "$t/nowhere" agl-image-minimal NIGHTLY_DATE=2026-11-26-0500)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no deploy directory'; then ok "a missing deploy directory is refused"; else bad "missing deploy directory accepted"; fi
out="$(collect "$t/tree4" third-image NIGHTLY_DATE=bad-date)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad NIGHTLY_DATE'; then ok "a bad date format is refused"; else bad "bad date accepted: $out"; fi
out="$(collect "$t/tree4" third-image NIGHTLY_COMMIT=abc)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad NIGHTLY_COMMIT'; then ok "a short commit is refused"; else bad "bad commit accepted: $out"; fi
out="$("$tool" --machine '../x' --target t --repo meta-agl 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a path in the machine name is refused"; else bad "path in machine name accepted"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
