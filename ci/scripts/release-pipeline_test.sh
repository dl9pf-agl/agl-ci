#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Integration test: the real release-collect.sh, release-attest.sh and kit/release/promote.sh in a row, on one fixture, with
# throw-away signing keys. It proves that the output of each step is what the next step expects (the unit tests of the scripts use
# fixtures of their own, which could drift apart from the real output).
# Run: ci/scripts/release-pipeline_test.sh   Needs cosign (COSIGN=/path or in PATH), jq and python3 with PyYAML; else SKIP, exit 0.
# The temporary directory it makes is left in place (path printed); remove it yourself.
#
# The story it tells, a release of two images of one machine that are built on DIFFERENT hosts:
#   1. each build job collects its files (release-collect.sh) into the staging area of ITS host and leaves two small files
#   2. the attest job gets the small files of both images, checks them and signs (release-attest.sh); its output is the release asset
#   3. the download server pulls both staging areas into one tree, an engineer countersigns (a file in agl-ucb), promote.sh fetches
#      and unpacks the asset, verifies everything and promotes
#   4. afterwards, from the outside, the published release verifies with the public key and with sha256sum
# and one attack: a big image file is changed AFTER it was collected (the signatures only cover hashes, so only promote can notice).
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
  echo "kernel of $target" > "$d/bzImage--6.18-$M.bin"; ln -s "bzImage--6.18-$M.bin" "$d/bzImage-$M.bin"      # each image has its own
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

export RELEASE_BRANCH=testrel RELEASE_VERSION=0.0.1

# 1. The build jobs, one per host: each collects into the staging area of its own host (what build.sh does through docker).
okc=1
out="$(AGL_TREE="$t/tree1" RELEASE_STAGING="$t/hostA/staging/release" "$here/release-collect.sh" --machine "$M" --target img1 --repo meta-agl 2>&1)" || { okc=0; echo "$out"; }
out="$(AGL_TREE="$t/tree2" RELEASE_STAGING="$t/hostB/staging/release" "$here/release-collect.sh" --machine "$M" --target img2 --repo meta-agl-demo 2>&1)" || { okc=0; echo "$out"; }
if [ "$okc" -eq 1 ]; then ok "release-collect.sh collected the two images on two hosts"; else bad "collect failed"; fi

# 2. The upload of the small files and its download in the attest job: both images' small files land in one directory.
small="$t/small"; mkdir -p "$small"
cp -r "$t/tree1/build/release-small/." "$small/"; cp -r "$t/tree2/build/release-small/." "$small/"
matrix='{"include":[{"repo":"meta-agl","machine":"qemux86-64","target":"img1"},{"repo":"meta-agl-demo","machine":"qemux86-64","target":"img2"}]}'
out="$(COSIGN="$cosign" COSIGN_SIGN_ARGS="$sign_args" COSIGN_VERIFY_ARGS="$verify_args" "$here/release-attest.sh" --small "$small" --pins "$pins" \
  --matrix "$matrix" --out "$t/signed" --branch testrel --version 0.0.1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "release-attest.sh accepted the output of release-collect.sh and signed it"; else bad "attest refused the collect output: $out"; fi
# The release asset, made the way release.yml makes it.
tar -C "$t/signed" -czf "$t/release-signed.tar.gz" .

# 3. The download server: the pull merges both staging areas; an engineer key and its signature (a file in a checkout of agl-ucb).
server="$t/server"; mkdir -p "$server/staging/release" "$t/ucb/kas/releases" "$t/keys/release"
cp -a "$t/hostA/staging/release/." "$server/staging/release/"; cp -a "$t/hostB/staging/release/." "$server/staging/release/"
( cd "$t" && mkdir -p keys-alice && cd keys-alice && "$cosign" generate-key-pair > /dev/null 2>&1 ); cp "$t/keys-alice/cosign.pub" "$t/keys/release/alice.pub"; : > "$t/keys/REVOKED.txt"
"$cosign" sign-blob --yes --key "$t/keys-alice/cosign.key" --tlog-upload=false --output-signature "$t/ucb/kas/releases/testrel_0.0.1.SHA256SUMS.alice.sig" "$t/signed/SHA256SUMS" > /dev/null 2>&1
promote() {   # promote ROOT: promote.sh with the key instead of the keyless identity and the asset from a file
  env RELEASE_ROOT="$1" RELEASE_UCB_DIR="$t/ucb" RELEASE_KEYS_DIR="$t/keys/release" COSIGN="$cosign" RELEASE_ASSET_URL="file://$t/release-signed.tar.gz" \
    RELEASE_CI_VERIFY_ARGS="$verify_args" "$here/../../kit/release/promote.sh" 2>&1
}

# 3a. The attack on a copy of the server tree: an image file changed after it was collected; the signed hashes do not match.
cp -a "$server" "$t/server-attacked"
echo "changed after collecting" >> "$t/server-attacked/staging/release/testrel/0.0.1/meta-agl/$M/img1/img1-$M.ext4.xz"
out="$(promote "$t/server-attacked")"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$t/server-attacked/release/testrel/0.0.1" ]; then ok "promote refuses an image file that changed after it was collected"; else bad "tampered image was promoted: $out"; fi

# 4. The real promote.
out="$(promote "$server")"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$server/release/testrel/0.0.1/PROMOTED" ]; then ok "promote.sh unpacked the asset, verified the combined tree and promoted the release"; else bad "promote refused: $out"; fi
r="$server/release/testrel/0.0.1"

# 5. From the outside, as a consumer: sha256sum -c, the signature of the top level and the attestation of each image.
if (cd "$r" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then ok "consumer: sha256sum -c SHA256SUMS"; else bad "consumer: top-level sums do not verify"; fi
# shellcheck disable=SC2086
if (cd "$r" && "$cosign" verify-blob --bundle SHA256SUMS.bundle $verify_args SHA256SUMS > /dev/null 2>&1); then ok "consumer: the signature of SHA256SUMS verifies"; else bad "consumer: top-level signature does not verify"; fi
allgood=1
for n in 1 2; do
  if [ "$n" = 1 ]; then d="$r/meta-agl/$M/img1"; else d="$r/meta-agl-demo/$M/img2"; fi
  (cd "$d" && sha256sum -c --quiet "img$n.SHA256SUMS" > /dev/null 2>&1) || allgood=0
  # shellcheck disable=SC2086
  "$cosign" verify-blob-attestation --type https://slsa.dev/provenance/v1 --bundle "$d/img$n.slsa.intoto.bundle" $verify_args "$d/img$n.SHA256SUMS" > /dev/null 2>&1 || allgood=0
done
if [ "$allgood" -eq 1 ]; then ok "consumer: both images' sums and attestations verify"; else bad "consumer: an image does not verify"; fi
if grep -qx "kernel of img1" "$r/meta-agl/$M/img1/bzImage-$M.bin" && grep -qx "kernel of img2" "$r/meta-agl-demo/$M/img2/bzImage-$M.bin" && [ -f "$r/pins_testrel_0.0.1.yml" ] && [ -f "$r/SHA256SUMS.alice.sig" ]; then ok "both kernels, pins file and the engineer's signature are in the release"; else bad "kernel, pins file or signature missing"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
