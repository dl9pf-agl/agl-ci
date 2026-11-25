#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of release-collect.sh with a fixture that looks like a real bitbake deploy directory (no kas, no docker, no network).
# Run: ci/scripts/release-collect_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
#
# What the fixture imitates (observed in the deploy directory of agl-image-minimal on qemux86-64, 2026-11-23):
#   every file twice: a plain name that is a link, and a name with a 14-digit timestamp that is the real file;
#   the kernel as bzImage (link), bzImage-<machine>.bin (link) and a versioned bzImage--<version>...bin (real file);
#   boot files (efi, efi.stub) as plain files; files of ANOTHER image of the same machine; and a directory.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/release-collect.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/release-collect-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

M=qemux86-64
# mkdeploy TREE TARGET KERNEL-TEXT: a tree with a deploy directory for TARGET and a kas statement.
#   KERNEL-TEXT is the content of the kernel file: two trees with different text simulate two images that disagree about the kernel.
mkdeploy() {
  local tree="$1" target="$2" kernel="$3" d="$1/build/tmp/deploy/images/$M"
  mkdir -p "$d/junk" "$1/build/attestation"
  local suffix
  for suffix in ext4.xz manifest spdx.json; do                 # the target's own files: real file with timestamp, plain-name link
    echo "$target $suffix" > "$d/$target-$M-20261123110250.$suffix"
    ln -s "$target-$M-20261123110250.$suffix" "$d/$target-$M.$suffix"
  done
  echo "$kernel" > "$d/bzImage--6.18.52-r0-$M-20261113184708.bin"          # the kernel: versioned real file and two links
  ln -s "bzImage--6.18.52-r0-$M-20261113184708.bin" "$d/bzImage-$M.bin"
  ln -s "bzImage-$M.bin" "$d/bzImage"
  echo grub > "$d/grub-efi-bootx64.efi"; echo stub > "$d/linuxx64.efi.stub"   # boot files
  echo "another image" > "$d/other-image-$M.ext4.xz"                          # belongs to another target: must NOT be collected
  echo "{\"statement\": \"$target\"}" > "$1/build/attestation/kas-build.provenance.json"
}
# collect TREE TARGET [extra env assignments...]: run the tool the way build.sh does.
collect() {
  local tree="$1" target="$2"; shift 2
  env AGL_TREE="$tree" RELEASE_STAGING="$t/stage" RELEASE_BRANCH=testrel RELEASE_VERSION=0.0.1 "$@" \
    "$tool" --machine "$M" --target "$target" 2>&1
}
part="$t/stage/testrel/0.0.1"
dest="$part/$M/deploy/images/$M"

# 1. Good case: the first image of the release.
mkdeploy "$t/tree1" agl-image-minimal kernel-A
out="$(collect "$t/tree1" agl-image-minimal)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "first image is collected"; else bad "first image refused: $out"; fi
# The plain names are in, as REAL files (links resolved), the timestamped copies and the other image are not.
if [ -f "$dest/agl-image-minimal-$M.ext4.xz" ] && [ ! -L "$dest/agl-image-minimal-$M.ext4.xz" ]; then ok "plain-named image file is a real file"; else bad "image file missing or still a link"; fi
if [ -f "$dest/bzImage-$M.bin" ] && [ ! -L "$dest/bzImage-$M.bin" ] && [ -f "$dest/bzImage" ] && [ ! -L "$dest/bzImage" ]; then ok "kernel files are real files"; else bad "kernel files missing or links"; fi
if [ -f "$dest/grub-efi-bootx64.efi" ] && [ -f "$dest/linuxx64.efi.stub" ]; then ok "boot files are in"; else bad "boot files missing"; fi
stamped=0; for f in "$dest"/*; do [[ "${f##*/}" =~ -[0-9]{14} ]] && stamped=1; done   # a 14-digit timestamp after a dash
if [ "$stamped" -eq 0 ]; then ok "no timestamped copies"; else bad "a timestamped copy was collected"; fi
if [ -e "$dest/other-image-$M.ext4.xz" ]; then bad "a file of another image was collected"; else ok "files of another image are left out"; fi
if [ -e "$dest/junk" ]; then bad "a directory was collected"; else ok "directories are left out"; fi
# The sums file verifies from its own directory, lists the statement, and does not list itself.
if (cd "$dest" && sha256sum -c --quiet agl-image-minimal.SHA256SUMS >/dev/null 2>&1); then ok "sha256sum -c of the sums file passes"; else bad "sums file does not verify"; fi
if grep -q ' agl-image-minimal.provenance.json$' "$dest/agl-image-minimal.SHA256SUMS"; then ok "the kas statement is listed in the sums"; else bad "statement not in the sums"; fi
if grep -q 'SHA256SUMS' "$dest/agl-image-minimal.SHA256SUMS"; then bad "the sums file lists itself"; else ok "the sums file does not list itself"; fi
# The two small files for the upload exist in the same relative layout.
small="$t/tree1/build/release-small/$M/deploy/images/$M"
if [ -f "$small/agl-image-minimal.SHA256SUMS" ] && [ -f "$small/agl-image-minimal.provenance.json" ]; then ok "small files copied for the upload"; else bad "small files missing"; fi

# 2. A second image of the same machine with the SAME kernel: allowed, the shared files are not copied twice.
mkdeploy "$t/tree2" other-image kernel-A
out="$(collect "$t/tree2" other-image)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "second image of the machine is collected"; else bad "second image refused: $out"; fi
if [ -f "$dest/other-image.SHA256SUMS" ] && [ -f "$dest/agl-image-minimal.SHA256SUMS" ]; then ok "both sums files side by side"; else bad "sums files missing"; fi
if grep -q ' bzImage-qemux86-64.bin$' "$dest/other-image.SHA256SUMS"; then ok "the shared kernel is listed in the second image's sums"; else bad "shared kernel not listed"; fi

# 3. A third image whose kernel DIFFERS from the one already in the release: must be refused (two images disagree).
mkdeploy "$t/tree3" third-image kernel-B
out="$(collect "$t/tree3" third-image)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'disagree'; then ok "a different kernel in the same release is refused"; else bad "kernel conflict accepted: $out"; fi

# 4. The same image twice in one release: refused.
out="$(collect "$t/tree1" agl-image-minimal)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already collected'; then ok "the same image twice is refused"; else bad "duplicate image accepted: $out"; fi

# 5. Another HOST of the same release: its own staging area, nothing shared. The download server merges the two later, so a
#    kernel that differs between the hosts is not seen here (promote.sh sees it: the sums of one image would not match).
mkdeploy "$t/tree4" other-host-image kernel-B
out="$(collect "$t/tree4" other-host-image RELEASE_STAGING="$t/stage2")"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$t/stage2/testrel/0.0.1/$M/deploy/images/$M/other-host-image.SHA256SUMS" ] && [ ! -e "$t/stage2/testrel/0.0.1/$M/deploy/images/$M/agl-image-minimal.SHA256SUMS" ]; then ok "an image on another host collects into that host's own staging area"; else bad "second host: $out"; fi

# 6. A leftover of a failed attempt (files, but no sums file): accepted when identical, so a rerun of the job works.
mkdeploy "$t/tree7" rerun-image kernel-A
collect "$t/tree7" rerun-image > /dev/null 2>&1; rm "$dest/rerun-image.SHA256SUMS"
out="$(collect "$t/tree7" rerun-image)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$dest/rerun-image.SHA256SUMS" ]; then ok "the rerun of a failed collect works"; else bad "rerun refused: $out"; fi

# 7. Missing input: no kas statement, no deploy directory, no file of the target.
mkdeploy "$t/tree5" agl-image-minimal kernel-A; rm "$t/tree5/build/attestation/kas-build.provenance.json"
out="$(collect "$t/tree5" agl-image-minimal RELEASE_VERSION=0.0.3)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no kas statement'; then ok "a missing kas statement is refused"; else bad "missing statement accepted"; fi
out="$(collect "$t/nowhere" agl-image-minimal RELEASE_VERSION=0.0.3)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no deploy directory'; then ok "a missing deploy directory is refused"; else bad "missing deploy directory accepted"; fi
mkdeploy "$t/tree6" agl-image-minimal kernel-A
out="$(collect "$t/tree6" no-such-target RELEASE_VERSION=0.0.3)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no file no-such-target'; then ok "a target without files is refused"; else bad "target without files accepted: $out"; fi

# 8. Bad names are refused before anything is written (they end up in paths and globs).
out="$(collect "$t/tree6" agl-image-minimal RELEASE_BRANCH=Vimba RELEASE_VERSION=0.0.4)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad RELEASE_BRANCH'; then ok "an upper case branch is refused"; else bad "bad branch accepted"; fi
out="$(collect "$t/tree6" agl-image-minimal RELEASE_VERSION=1.2)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad RELEASE_VERSION'; then ok "a short version is refused"; else bad "bad version accepted"; fi
out="$("$tool" --machine '../x' --target t 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a path in the machine name is refused"; else bad "path in machine name accepted"; fi
# None of the refused calls above (versions 0.0.3, 0.0.4) may have created a release directory.
left=0; for v in 0.0.3 0.0.4; do [ ! -e "$t/stage/testrel/$v" ] || left=1; done
if [ "$left" -eq 0 ]; then ok "refused calls left nothing behind"; else bad "a refused call left a directory"; fi

# 9. trowl-report/ (ci/scripts/build.sh's trowl scan step, AGL_TROWL=1): a whole directory, carried into the release, its
#    files listed in the sums (promote.sh's own checks then cover the merged/signed/asset flow; not retested here).
mkdeploy "$t/tree8" agl-image-minimal kernel-A
mkdir -p "$t/tree8/build/tmp/deploy/images/$M/trowl-report"
echo '<html></html>' > "$t/tree8/build/tmp/deploy/images/$M/trowl-report/index.html"
echo '{}' > "$t/tree8/build/tmp/deploy/images/$M/trowl-report/report.json"
out="$(collect "$t/tree8" agl-image-minimal RELEASE_VERSION=0.0.5)"; rc=$?
tdest="$t/stage/testrel/0.0.5/$M/deploy/images/$M"
if [ "$rc" -eq 0 ] && [ -f "$tdest/trowl-report/index.html" ] && [ -f "$tdest/trowl-report/report.json" ]; then
  ok "trowl-report/ is collected recursively"
else bad "trowl-report/ missing or collect failed: $out"; fi
if grep -q ' trowl-report/index.html$' "$tdest/agl-image-minimal.SHA256SUMS" && grep -q ' trowl-report/report.json$' "$tdest/agl-image-minimal.SHA256SUMS"; then
  ok "trowl-report/'s files are listed in the sums"
else bad "trowl-report/ not in the sums: $(cat "$tdest/agl-image-minimal.SHA256SUMS")"; fi
if (cd "$tdest" && sha256sum -c --quiet agl-image-minimal.SHA256SUMS >/dev/null 2>&1); then
  ok "the sums file verifies with trowl-report/ included"
else bad "sums file with trowl-report/ does not verify"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
