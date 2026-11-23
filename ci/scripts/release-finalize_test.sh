#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of release-finalize.sh with a small fixture (no docker, no cosign, no network). Run: ci/scripts/release-finalize_test.sh
# The temporary directory it makes is left in place (path printed); remove it yourself.
#
# What the fixture is: the state the earlier steps leave behind.
#   <stage>/testrel/.0.0.1.partial/        what release-collect.sh wrote: one image (images, kernel, statement), its per-image
#                                          sums file, and the hidden run marker
#   <signed>/                              what the attest job returns: the per-image sums file and statement again (identical),
#                                          the image's attestation bundle, the pins file, and the top-level SHA256SUMS + its bundle
# The bundles here are plain text: this script never looks inside them (the signatures are checked by the attest job and, later,
# by promote); it only checks hashes and file sets.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/release-finalize.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/release-finalize-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

M=qemux86-64
# fixture NAME: build $t/NAME/stage and $t/NAME/signed as described above.
fixture() {
  local d="$t/$1" part img sg
  part="$d/stage/testrel/.0.0.1.partial"; img="$part/$M/deploy/images/$M"; sg="$d/signed/$M/deploy/images/$M"
  mkdir -p "$img" "$sg"
  echo "image data" > "$img/img-$M.ext4.xz"; echo "kernel" > "$img/bzImage-$M.bin"; echo '{"statement":1}' > "$img/img.provenance.json"
  ( cd "$img" && sha256sum -- img-$M.ext4.xz bzImage-$M.bin img.provenance.json > img.SHA256SUMS )
  echo run1 > "$part/.run-id"
  # the attest job's output: copies of the sums and the statement, the attestation bundle, the pins file
  cp "$img/img.SHA256SUMS" "$img/img.provenance.json" "$sg/"
  echo "attestation bundle" > "$sg/img.slsa.intoto.bundle"
  echo "header: {version: 22}" > "$d/signed/pins_testrel_0.0.1.yml"
  # the top-level sums file lists everything the attest job produced (paths relative to the release root), then its own bundle
  ( cd "$d/signed" && sha256sum -- "$M/deploy/images/$M/img.SHA256SUMS" "$M/deploy/images/$M/img.provenance.json" \
      "$M/deploy/images/$M/img.slsa.intoto.bundle" pins_testrel_0.0.1.yml > SHA256SUMS )
  echo "top-level bundle" > "$d/signed/SHA256SUMS.bundle"
}
# finalize NAME [extra env assignments...]: run the tool on the fixture NAME.
finalize() {
  local n="$1"; shift
  env RELEASE_STAGING="$t/$n/stage" RELEASE_BRANCH=testrel RELEASE_VERSION=0.0.1 RELEASE_RUN_ID=run1 RELEASE_SIGNED_DIR="$t/$n/signed" "$@" "$tool" 2>&1
}

# 1. Good case: the release is verified and renamed; the partial directory is gone; the signed files are in place.
fixture good
out="$(finalize good)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a good release is finalized"; else bad "good release refused: $out"; fi
if [ -d "$t/good/stage/testrel/0.0.1" ] && [ ! -e "$t/good/stage/testrel/.0.0.1.partial" ]; then ok "the partial directory was renamed to the release"; else bad "rename did not happen"; fi
r="$t/good/stage/testrel/0.0.1"
if [ -f "$r/SHA256SUMS" ] && [ -f "$r/SHA256SUMS.bundle" ] && [ -f "$r/pins_testrel_0.0.1.yml" ] && [ -f "$r/$M/deploy/images/$M/img.slsa.intoto.bundle" ]; then ok "signed files are placed in the layout"; else bad "signed files missing in the release"; fi
if echo "$out" | grep -q 'every file is listed'; then ok "the unlisted-files check ran and passed"; else bad "unlisted-files check did not run"; fi

# 2. A big file changed after the build job hashed it: the per-image sums no longer match. Must be refused, nothing renamed.
fixture tamper
echo "changed" >> "$t/tamper/stage/testrel/.0.0.1.partial/$M/deploy/images/$M/img-$M.ext4.xz"
out="$(finalize tamper)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'does not verify'; then ok "a changed image file is refused"; else bad "changed image file accepted: $out"; fi
if [ ! -e "$t/tamper/stage/testrel/0.0.1" ]; then ok "a refused release is not renamed"; else bad "refused release was published"; fi

# 3. The attest job's copy of a per-image sums file differs from the one the build job wrote.
fixture sumsdiff
echo "0000  other" >> "$t/sumsdiff/signed/$M/deploy/images/$M/img.SHA256SUMS"
out="$(finalize sumsdiff)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'differs between the build jobs and the attest job'; then ok "a changed per-image sums file is refused"; else bad "changed sums accepted: $out"; fi

# 4. A file that nobody lists (a stray file, or a leftover <name>.tmp of a failed copy).
fixture extra
echo "stray" > "$t/extra/stage/testrel/.0.0.1.partial/$M/deploy/images/$M/stray.txt"
out="$(finalize extra)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'not listed anywhere: .*stray.txt'; then ok "an unlisted file is refused"; else bad "unlisted file accepted: $out"; fi
fixture tmpfile
echo "half" > "$t/tmpfile/stage/testrel/.0.0.1.partial/$M/deploy/images/$M/bzImage-$M.bin.tmp"
out="$(finalize tmpfile)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'not listed anywhere'; then ok "a leftover .tmp file is refused"; else bad "tmp file accepted: $out"; fi

# 5. The bundle of an image was changed after the top-level sums file was made: the top-level hash no longer matches.
fixture bundle
echo "tampered" > "$t/bundle/signed/$M/deploy/images/$M/img.slsa.intoto.bundle"
out="$(finalize bundle)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'SHA256SUMS does not verify'; then ok "a changed bundle is refused"; else bad "changed bundle accepted: $out"; fi

# 6. State errors: another run's partial directory, a release that exists, missing signed files, missing partial directory.
fixture otherrun
out="$(finalize otherrun RELEASE_RUN_ID=run2)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'does not carry run id run2'; then ok "the partial directory of another run is refused"; else bad "foreign partial accepted: $out"; fi
fixture exists
mkdir -p "$t/exists/stage/testrel/0.0.1"
out="$(finalize exists)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'already exists'; then ok "an existing release is refused"; else bad "existing release accepted: $out"; fi
fixture nobundle
mv "$t/nobundle/signed/SHA256SUMS.bundle" "$t/nobundle/signed/moved"
out="$(finalize nobundle)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'lacks SHA256SUMS'; then ok "missing top-level signature files are refused"; else bad "missing bundle accepted: $out"; fi
fixture nopartial
mv "$t/nopartial/stage/testrel/.0.0.1.partial" "$t/nopartial/stage/testrel/moved"
out="$(finalize nopartial)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no partial directory'; then ok "a missing partial directory is refused"; else bad "missing partial accepted: $out"; fi

# 7. Bad names.
fixture names
out="$(finalize names RELEASE_BRANCH=Vimba)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad RELEASE_BRANCH'; then ok "an upper case branch is refused"; else bad "bad branch accepted"; fi
out="$(finalize names RELEASE_VERSION=1.2)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad RELEASE_VERSION'; then ok "a short version is refused"; else bad "bad version accepted"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
