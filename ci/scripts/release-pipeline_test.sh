#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Integration test: the real release-collect.sh, release-attest.sh and release-finalize.sh in a row, on one fixture, with a
# throw-away signing key. It proves that the output of each step is what the next step expects (the unit tests of the three scripts
# use fixtures of their own, which could drift apart from the real output).
# Run: ci/scripts/release-pipeline_test.sh   Needs cosign (COSIGN=/path or in PATH), jq and python3 with PyYAML; else SKIP, exit 0.
# The temporary directory it makes is left in place (path printed); remove it yourself.
#
# The story it tells, as in a real release of two images of one machine:
#   1. each build job collects its files (release-collect.sh) into the release staging area and leaves two small files
#   2. the attest job gets the small files of both images, checks them and signs (release-attest.sh)
#   3. the finalize job places the signed files, verifies everything against the real files and publishes (release-finalize.sh)
#   4. afterwards, from the outside, the published release verifies with the public key and with sha256sum
# and one attack: a big image file is changed AFTER it was collected (the signatures only cover hashes, so only finalize can notice).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cosign="${COSIGN:-$(command -v cosign || true)}"
if [ -z "$cosign" ] || [ ! -x "$cosign" ]; then echo "SKIP: no cosign (set COSIGN=/path/to/cosign)"; exit 0; fi
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: no PyYAML"; exit 0; }
t="$(mktemp -d "${TMPDIR:-/tmp}/release-pipeline-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

M=qemux86-64
export COSIGN_PASSWORD=testonly
( cd "$t" && "$cosign" generate-key-pair > /dev/null 2>&1 )
sign_args="--key $t/cosign.key --tlog-upload=false"
verify_args="--key $t/cosign.pub --insecure-ignore-tlog=true"

# The pins file of the release and, per image, a deploy directory plus a kas-like statement that matches the pins file.
pins="$t/pins_testrel_0.0.1.yml"
# mktree TREE TARGET: a build tree as a release build job leaves it: deploy directory (plain-name links) and the kas statement.
mktree() {
  local tree="$1" target="$2" d="$1/build/tmp/deploy/images/$M"
  mkdir -p "$d" "$tree/build/attestation"
  local suffix
  for suffix in ext4.xz manifest; do
    echo "$target $suffix" > "$d/$target-$M-20261123110250.$suffix"; ln -s "$target-$M-20261123110250.$suffix" "$d/$target-$M.$suffix"
  done
  echo "kernel" > "$d/bzImage--6.18-$M.bin"; ln -s "bzImage--6.18-$M.bin" "$d/bzImage-$M.bin"      # the same kernel in both trees
  python3 - "$tree/build/attestation/kas-build.provenance.json" "$pins" "$target" <<'EOF'
import base64, json, sys
out, pins, target = sys.argv[1:4]
sha = lambda n: f"a{n:039x}"
pins_text = f"header:\n  version: 22\noverrides:\n  repos:\n    meta-agl:\n      commit: {sha(1)}\n    bitbake:\n      commit: {sha(2)}\n"
open(pins, "w").write(pins_text)
repo = lambda n, c: {"name": n, "uri": f"git+https://example.org/{n}.git", "digest": {"gitCommit": c}, "annotations": {"dirty": False, "layers": []}}
st = {"_type": "https://in-toto.io/Statement/v1", "predicateType": "https://slsa.dev/provenance/v1",
      "subject": [{"name": f"{target}.manifest", "digest": {"sha256": "0" * 64}}],
      "predicate": {"buildDefinition": {"buildType": "kas", "externalParameters": {"target": [target]}, "internalParameters": {},
                    "resolvedDependencies": [repo("meta-agl", sha(1)), repo("bitbake", sha(2)),
                                             {"name": "kas/pins.yml", "content": base64.b64encode(pins_text.encode()).decode()}]},
                    "runDetails": {"builder": {"id": "https://github.com/siemens/kas"}}}}
json.dump(st, open(out, "w"), indent=1)
EOF
}
mktree "$t/tree1" img1
mktree "$t/tree2" img2

stage="$t/stage/release"          # the release area of the cache directory
export RELEASE_STAGING="$stage" RELEASE_BRANCH=testrel RELEASE_VERSION=0.0.1 RELEASE_RUN_ID=run1

# 1. The build jobs: each collects its files (what build.sh does through docker in the real run).
ok_collect=1
for n in 1 2; do
  out="$(AGL_TREE="$t/tree$n" "$here/release-collect.sh" --machine "$M" --target "img$n" 2>&1)" || { ok_collect=0; echo "$out"; }
done
if [ "$ok_collect" -eq 1 ]; then ok "release-collect.sh collected both images"; else bad "collect failed"; fi

# 2. The upload of the small files and its download in the attest job: both images' small files land in one directory.
small="$t/small"; mkdir -p "$small"
cp -r "$t/tree1/build/release-small/." "$small/"; cp -r "$t/tree2/build/release-small/." "$small/"
matrix='{"include":[{"machine":"qemux86-64","target":"img1"},{"machine":"qemux86-64","target":"img2"}]}'
out="$(COSIGN="$cosign" COSIGN_SIGN_ARGS="$sign_args" COSIGN_VERIFY_ARGS="$verify_args" "$here/release-attest.sh" --small "$small" --pins "$pins" \
  --matrix "$matrix" --out "$t/signed" --branch testrel --version 0.0.1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "release-attest.sh accepted the output of release-collect.sh and signed it"; else bad "attest refused the collect output: $out"; fi

# 3. Before finalize: an attack on a copy of the staging area, to see that finalize is the one that notices a changed big file.
cp -a "$stage" "$t/stage-attacked"
echo "changed after collecting" >> "$t/stage-attacked/testrel/.0.0.1.partial/$M/deploy/images/$M/img1-$M.ext4.xz"
out="$(RELEASE_STAGING="$t/stage-attacked" RELEASE_SIGNED_DIR="$t/signed" "$here/release-finalize.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$t/stage-attacked/testrel/0.0.1" ]; then ok "finalize refuses an image file that changed after it was collected"; else bad "tampered image was published: $out"; fi

# 4. The real finalize.
out="$(RELEASE_SIGNED_DIR="$t/signed" "$here/release-finalize.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "release-finalize.sh accepted the output of the attest step and published the release"; else bad "finalize refused: $out"; fi
r="$stage/testrel/0.0.1"
if [ -d "$r" ] && [ ! -e "$stage/testrel/.0.0.1.partial" ]; then ok "the release directory exists, the partial one is gone"; else bad "publication did not happen"; fi

# 5. From the outside, as a consumer: sha256sum -c, the signature of the top level and the attestation of each image.
if (cd "$r" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then ok "consumer: sha256sum -c SHA256SUMS"; else bad "consumer: top-level sums do not verify"; fi
# shellcheck disable=SC2086
if (cd "$r" && "$cosign" verify-blob --bundle SHA256SUMS.bundle $verify_args SHA256SUMS > /dev/null 2>&1); then ok "consumer: the signature of SHA256SUMS verifies"; else bad "consumer: top-level signature does not verify"; fi
allgood=1
for n in 1 2; do
  d="$r/$M/deploy/images/$M"
  (cd "$d" && sha256sum -c --quiet "img$n.SHA256SUMS" > /dev/null 2>&1) || allgood=0
  # shellcheck disable=SC2086
  "$cosign" verify-blob-attestation --type https://slsa.dev/provenance/v1 --bundle "$d/img$n.slsa.intoto.bundle" $verify_args "$d/img$n.SHA256SUMS" > /dev/null 2>&1 || allgood=0
done
if [ "$allgood" -eq 1 ]; then ok "consumer: both images' sums and attestations verify"; else bad "consumer: an image does not verify"; fi
if [ -f "$r/$M/deploy/images/$M/bzImage-$M.bin" ] && [ -f "$r/pins_testrel_0.0.1.yml" ]; then ok "kernel (shared) and pins file are in the release"; else bad "kernel or pins file missing"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
