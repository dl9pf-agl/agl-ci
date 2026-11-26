#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of release-attest.sh with a throw-away signing key (no network, no GitHub identity).
# Run: ci/scripts/release-attest_test.sh      Needs cosign: set COSIGN=/path/to/cosign, or have cosign in PATH. Without it the test
# says SKIP and exits 0 (the lint runner image has no cosign; the keyless signing is proven by the rehearsal run, not here).
# The temporary directory it makes is left in place (path printed); remove it yourself.
#
# What it proves: with a key instead of the keyless identity, the script
#   - attests each image's sums file and signs the top-level sums file, and what it made verifies independently with the public key;
#   - refuses to sign anything when a statement does not match the pins file;
#   - refuses missing files, a bad matrix and an output directory that exists;
#   - and that the signatures really cover the content: changing a sums file afterwards breaks the verification.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/release-attest.sh"
cosign="${COSIGN:-$(command -v cosign || true)}"
if [ -z "$cosign" ] || [ ! -x "$cosign" ]; then echo "SKIP: no cosign (set COSIGN=/path/to/cosign)"; exit 0; fi
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
t="$(mktemp -d "${TMPDIR:-/tmp}/release-attest-test.XXXXXX")"
echo "test directory: $t (cosign: $("$cosign" version 2>&1 | sed -n 's/^GitVersion: *//p'))"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

# A throw-away key pair for signing and verifying; the password is only for this test.
export COSIGN_PASSWORD=testonly
( cd "$t" && "$cosign" generate-key-pair > /dev/null 2>&1 )
sign_args="--key $t/cosign.key --tlog-upload=false"          # in the workflow this is empty: keyless
verify_args="--key $t/cosign.pub --insecure-ignore-tlog=true"  # in the workflow: the certificate identity and issuer

M=qemux86-64
# The pins file and two images (img1, img2) of one machine, each with a statement that matches the pins and a sums file that lists it.
pins="$t/pins_testrel_0.0.1.yml"
python3 - "$t" "$pins" <<'EOF'
import base64, hashlib, json, sys
t, pins = sys.argv[1], sys.argv[2]
M = "qemux86-64"
sha = lambda n: f"a{n:039x}"                  # a fake 40-hex commit id
pins_text = f"header:\n  version: 22\noverrides:\n  repos:\n    meta-agl:\n      commit: {sha(1)}\n    bitbake:\n      commit: {sha(2)}\n"
open(pins, "w").write(pins_text)
def statement(target, dirty=False):
    repo = lambda n, c, d=False: {"name": n, "uri": f"git+https://example.org/{n}.git", "digest": {"gitCommit": c}, "annotations": {"dirty": d, "layers": []}}
    return {"_type": "https://in-toto.io/Statement/v1", "predicateType": "https://slsa.dev/provenance/v1",
            "subject": [{"name": "x", "digest": {"sha256": "0" * 64}}],
            "predicate": {"buildDefinition": {"buildType": "kas", "externalParameters": {"target": [target]}, "internalParameters": {},
                          "resolvedDependencies": [repo("meta-agl", sha(1), dirty), repo("bitbake", sha(2)),
                                                   {"name": "kas/pins.yml", "content": base64.b64encode(pins_text.encode()).decode()}]},
                          "runDetails": {"builder": {"id": "https://github.com/siemens/kas"}}}}
import os
for variant, targets in (("small", ["img1", "img2"]), ("dirty", ["img1", "img2"])):
    for target in targets:
        d = f"{t}/{variant}/meta-agl/{M}/{target}"
        os.makedirs(d, exist_ok=True)
        stmt = json.dumps(statement(target, dirty=(variant == "dirty" and target == "img2")), indent=1).encode()
        open(f"{d}/{target}.provenance.json", "wb").write(stmt)
        open(f"{d}/{target}.SHA256SUMS", "w").write(f"{hashlib.sha256(stmt).hexdigest()}  {target}.provenance.json\n{'b' * 64}  {target}-{M}.ext4.xz\n")
EOF
matrix='{"include":[{"repo":"meta-agl","machine":"qemux86-64","target":"img1"},{"repo":"meta-agl","machine":"qemux86-64","target":"img2"}]}'
attest() {   # attest SMALL OUT [extra args]: run the tool with the key
  local small="$1" out="$2"; shift 2
  env COSIGN="$cosign" COSIGN_SIGN_ARGS="$sign_args" COSIGN_VERIFY_ARGS="$verify_args" "$tool" --small "$small" --pins "$pins" \
    --matrix "$matrix" --out "$out" --branch testrel --version 0.0.1 "$@" 2>&1
}

# 1. Good case.
out="$(attest "$t/small" "$t/out1")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "two images are attested and the top level is signed"; else bad "good case refused: $out"; fi
o="$t/out1"; d="$o/meta-agl/$M/img1"; d2="$o/meta-agl/$M/img2"
if [ -f "$d/img1.slsa.intoto.bundle" ] && [ -f "$d2/img2.slsa.intoto.bundle" ] && [ -f "$o/SHA256SUMS" ] && [ -f "$o/SHA256SUMS.bundle" ] && [ -f "$o/pins_testrel_0.0.1.yml" ]; then ok "bundles, top-level files and pins file are in the output"; else bad "output files missing"; fi
if [ -f "$d/img1.SHA256SUMS" ] && [ -f "$d/img1.provenance.json" ]; then ok "the sums files and statements are passed on"; else bad "sums or statements missing in the output"; fi
# What was made verifies independently of the script, with the public key.
# shellcheck disable=SC2086
if "$cosign" verify-blob-attestation --type https://slsa.dev/provenance/v1 --bundle "$d/img1.slsa.intoto.bundle" $verify_args "$d/img1.SHA256SUMS" >/dev/null 2>&1; then ok "the attestation of img1 verifies with the public key"; else bad "img1 attestation does not verify"; fi
# shellcheck disable=SC2086
if (cd "$o" && "$cosign" verify-blob --bundle SHA256SUMS.bundle $verify_args SHA256SUMS >/dev/null 2>&1); then ok "the top-level signature verifies with the public key"; else bad "top-level signature does not verify"; fi
if (cd "$o" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then ok "sha256sum -c of the top-level file passes"; else bad "top-level sums do not verify"; fi
if grep -q 'img1.slsa.intoto.bundle' "$o/SHA256SUMS" && grep -q "pins_testrel_0.0.1.yml" "$o/SHA256SUMS" && grep -q 'img2.provenance.json' "$o/SHA256SUMS"; then ok "the top level lists bundles, pins file and statements"; else bad "top-level list incomplete"; fi
if grep -q 'SHA256SUMS.bundle' "$o/SHA256SUMS"; then bad "the top level lists its own bundle"; else ok "the top level does not list its own bundle"; fi
# The predicate in the attestation is the one of the statement (the custom type URI keeps it byte-identical).
if python3 - "$d/img1.slsa.intoto.bundle" "$d/img1.provenance.json" <<'EOF'
import base64, json, sys
b = json.load(open(sys.argv[1])); env = json.loads(base64.b64decode(b["base64Signature"]))
st = json.loads(base64.b64decode(env["payload"])); orig = json.load(open(sys.argv[2]))
sys.exit(0 if st["predicate"] == orig["predicate"] and st["predicateType"] == "https://slsa.dev/provenance/v1" else 1)
EOF
then ok "the attested predicate equals the statement's predicate"; else bad "the predicate was changed"; fi

# 2. What was signed is covered: a changed sums file breaks the verification.
echo "0000  tampered" >> "$d/img1.SHA256SUMS"
# shellcheck disable=SC2086
if "$cosign" verify-blob-attestation --type https://slsa.dev/provenance/v1 --bundle "$d/img1.slsa.intoto.bundle" $verify_args "$d/img1.SHA256SUMS" >/dev/null 2>&1; then bad "a changed sums file still verifies"; else ok "a changed sums file no longer verifies"; fi
if (cd "$o" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then bad "the top level does not notice a changed sums file"; else ok "the top level notices a changed sums file"; fi

# 3. A statement that does not match the pins file (a dirty repo in img2): nothing is signed, not even for img1.
out="$(attest "$t/dirty" "$t/out2")"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'does not match the pins file'; then ok "a bad statement stops the run"; else bad "bad statement accepted: $out"; fi
if [ -e "$t/out2/SHA256SUMS" ] || [ -e "$t/out2/SHA256SUMS.bundle" ]; then bad "a top-level file was written although a statement failed"; else ok "no top-level file was written"; fi

# 4. Missing input and bad arguments.
out="$(attest "$t/small" "$t/out3" --matrix '{"include":[{"repo":"meta-agl","machine":"qemux86-64","target":"img3"}]}')"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'missing'; then ok "an image without files is refused"; else bad "missing image files accepted: $out"; fi
out="$(attest "$t/small" "$t/out4" --matrix 'not json')"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a matrix that is not JSON is refused"; else bad "bad matrix accepted"; fi
out="$(attest "$t/small" "$t/out1")"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'does not exist yet'; then ok "an existing output directory is refused"; else bad "existing output accepted: $out"; fi
out="$(attest "$t/small" "$t/out5" --matrix '{"include":[{"repo":"meta-agl","machine":"../x","target":"img1"}]}')"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad names'; then ok "a path in a matrix name is refused"; else bad "bad name accepted: $out"; fi
out="$(attest "$t/small" "$t/out7" --matrix '{"include":[{"machine":"qemux86-64","target":"img1"}]}')"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad names'; then ok "a matrix entry without repo is refused"; else bad "missing repo accepted: $out"; fi
out="$(attest "$t/small" "$t/out6" --version 1.2)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'bad --version'; then ok "a short version is refused"; else bad "bad version accepted"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
