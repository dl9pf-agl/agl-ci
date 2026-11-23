#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of promote.sh with throw-away keys (no network, no GitHub identity). Run: kit/release/promote_test.sh
# Needs cosign (COSIGN=/path or in PATH), else SKIP and exit 0. The temporary directory it makes is left in place (path printed).
#
# Keys: "ci" stands for the keyless CI identity (promote.sh gets RELEASE_CI_VERIFY_ARGS with its public key), "alice" and "bob"
# are release engineers. Each case builds a fresh fixture: a release as release-attest.sh + release-finalize.sh leave it, in
# staging/release/testrel/0.0.1, plus engineers' signature files in a fake agl-ucb checkout.
# shellcheck disable=SC2015   # "condition && ok || bad" is the idiom of this test; ok never fails, so bad runs only when the condition does not hold
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/promote.sh"
cosign="${COSIGN:-$(command -v cosign || true)}"
if [ -z "$cosign" ] || [ ! -x "$cosign" ]; then echo "SKIP: no cosign (set COSIGN=/path/to/cosign)"; exit 0; fi
t="$(mktemp -d "${TMPDIR:-/tmp}/promote-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
export COSIGN_PASSWORD=testonly
for k in ci ci2 alice bob mallory; do ( mkdir -p "$t/keys-$k" && cd "$t/keys-$k" && "$cosign" generate-key-pair > /dev/null 2>&1 ); done
M=qemux86-64; TAG=testrel_0.0.1
sig_args="--tlog-upload=false"

# mk NAME: a fixture in $t/NAME: root/staging/release/testrel/0.0.1, keys (alice, bob), ucb with signatures of alice only.
mk() {
  local d="$t/$1" s img
  s="$d/root/staging/release/testrel/0.0.1"; img="$s/$M/deploy/images/$M"
  mkdir -p "$img" "$d/keys/release" "$d/ucb/kas/releases"
  cp "$t/keys-alice/cosign.pub" "$d/keys/release/alice.pub"; cp "$t/keys-bob/cosign.pub" "$d/keys/release/bob.pub"; : > "$d/keys/REVOKED.txt"
  echo "image" > "$img/img-$M.ext4.xz"; echo "kernel" > "$img/bzImage-$M.bin"; echo '{"statement":1}' > "$img/img.provenance.json"
  ( cd "$img" && sha256sum -- "img-$M.ext4.xz" "bzImage-$M.bin" img.provenance.json > img.SHA256SUMS
    echo '{}' > "$d/predicate.json"
    "$cosign" attest-blob --yes --key "$t/keys-ci/cosign.key" $sig_args --type https://slsa.dev/provenance/v1 --predicate "$d/predicate.json" \
      --bundle img.slsa.intoto.bundle img.SHA256SUMS > /dev/null 2>&1 )
  echo "pins" > "$s/pins_testrel_0.0.1.yml"
  ( cd "$s" && sha256sum -- "$M/deploy/images/$M/img.SHA256SUMS" "$M/deploy/images/$M/img.provenance.json" "$M/deploy/images/$M/img.slsa.intoto.bundle" pins_testrel_0.0.1.yml > SHA256SUMS
    "$cosign" sign-blob --yes --key "$t/keys-ci/cosign.key" $sig_args --bundle SHA256SUMS.bundle SHA256SUMS > /dev/null 2>&1 )
  esign "$d" alice
}
# esign DIR ID: the engineer ID signs the staged top-level sums and commits the signature to the fake agl-ucb.
esign() { "$cosign" sign-blob --yes --key "$t/keys-$2/cosign.key" $sig_args --output-signature "$1/ucb/kas/releases/$TAG.SHA256SUMS.$2.sig" "$1/root/staging/release/testrel/0.0.1/SHA256SUMS" > /dev/null 2>&1; }
# run NAME [env...]: promote.sh on fixture NAME (CI verified with the public key of "ci").
run() {
  local n="$1"; shift
  env RELEASE_ROOT="$t/$n/root" RELEASE_UCB_DIR="$t/$n/ucb" RELEASE_KEYS_DIR="$t/$n/keys/release" COSIGN="$cosign" \
    RELEASE_CI_VERIFY_ARGS="--key $t/keys-ci/cosign.pub --insecure-ignore-tlog=true" "$@" "$tool" 2>&1
}
# runh NAME: the same, with the release named on the command line (by hand).
runh() { env RELEASE_ROOT="$t/$1/root" RELEASE_UCB_DIR="$t/$1/ucb" RELEASE_KEYS_DIR="$t/$1/keys/release" COSIGN="$cosign" \
    RELEASE_CI_VERIFY_ARGS="--key $t/keys-ci/cosign.pub --insecure-ignore-tlog=true" "$tool" testrel 0.0.1 2>&1; }
promoted() { [ -f "$t/$1/root/release/testrel/0.0.1/PROMOTED" ]; }

# 1. Good release, auto mode: promoted by a copy, signature and PROMOTED in place, staging stays; a second run changes nothing.
mk good
out="$(run good)"; rc=$?
if [ "$rc" -eq 0 ] && promoted good; then ok "a good release is promoted"; else bad "good release not promoted: $out"; fi
r="$t/good/root/release/testrel/0.0.1"
[ -f "$r/SHA256SUMS.alice.sig" ] && ok "the engineer's signature is part of the release" || bad "signature file missing in release"
[ -f "$t/good/root/staging/release/testrel/0.0.1/SHA256SUMS" ] && [ ! -e "$t/good/root/staging/release/testrel/0.0.1/PROMOTED" ] && ok "the staging copy stays, unmarked" || bad "staging copy changed"
out="$(run good)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$t/good/root/release-done.txt" ]; then ok "a second run changes nothing"; else bad "second run: $out"; fi
[ -f "$t/good/root/staging/release/STAGING.txt" ] && ok "STAGING.txt is written" || bad "no STAGING.txt"

# 2. Manual mode: all checks, no promotion; then the named release is promoted by hand.
mk manual
out="$(run manual RELEASE_PROMOTE=manual)"; rc=$?
if [ "$rc" -eq 0 ] && ! promoted manual && echo "$out" | grep -q 'manual mode, NOT promoted'; then ok "manual mode verifies but does not promote"; else bad "manual mode: $out"; fi
out="$(runh manual)"; promoted manual && ok "promote.sh <branch> <version> promotes by hand" || bad "hand promotion failed (manual env was off): $out"

# 3. Each fault is refused and nothing is promoted.
mk changed; echo "x" >> "$t/changed/root/staging/release/testrel/0.0.1/$M/deploy/images/$M/img-$M.ext4.xz"
out="$(run changed)"; rc=$?; [ "$rc" -ne 0 ] && ! promoted changed && echo "$out" | grep -q 'does not verify' && ok "a changed file is refused" || bad "changed file: $out"
mk extra; echo "stray" > "$t/extra/root/staging/release/testrel/0.0.1/stray.txt"
out="$(run extra)"; rc=$?; [ "$rc" -ne 0 ] && ! promoted extra && echo "$out" | grep -q 'nobody lists: stray.txt' && ok "an extra file is refused" || bad "extra file: $out"
mk link; ln -s /etc/passwd "$t/link/root/staging/release/testrel/0.0.1/link"
out="$(run link)"; rc=$?; [ "$rc" -ne 0 ] && ! promoted link && echo "$out" | grep -q 'symlink' && ok "a symlink is refused" || bad "symlink: $out"
mk nobundle; rm "$t/nobundle/root/staging/release/testrel/0.0.1/$M/deploy/images/$M/img.slsa.intoto.bundle"
out="$(run nobundle)"; rc=$?; [ "$rc" -ne 0 ] && ! promoted nobundle && ok "a missing attestation bundle is refused" || bad "missing bundle: $out"
mk wrongci
out="$(run wrongci RELEASE_CI_VERIFY_ARGS="--key $t/keys-ci2/cosign.pub --insecure-ignore-tlog=true")"; rc=$?
[ "$rc" -ne 0 ] && ! promoted wrongci && echo "$out" | grep -q 'CI signature' && ok "a wrong CI identity is refused" || bad "wrong CI: $out"
mk tampersums; echo "0000  x" >> "$t/tampersums/root/staging/release/testrel/0.0.1/SHA256SUMS"
out="$(run tampersums)"; rc=$?; [ "$rc" -ne 0 ] && ! promoted tampersums && ok "a changed top-level sums file is refused (CI signature)" || bad "tampered sums: $out"

# 4. Engineer signatures: waiting is not an error and not a promotion.
mk wrongkey; rm "$t/wrongkey/ucb/kas/releases/"*.sig; esign "$t/wrongkey" mallory; cp "$t/wrongkey/ucb/kas/releases/$TAG.SHA256SUMS.mallory.sig" "$t/wrongkey/ucb/kas/releases/$TAG.SHA256SUMS.alice.sig"
out="$(run wrongkey)"; rc=$?; [ "$rc" -eq 0 ] && ! promoted wrongkey && echo "$out" | grep -q 'does not verify, ignored' && ok "a signature by another key does not count (waits)" || bad "wrong key: $out"
mk unknown; rm "$t/unknown/ucb/kas/releases/"*.sig; esign "$t/unknown" mallory
out="$(run unknown)"; rc=$?; [ "$rc" -eq 0 ] && ! promoted unknown && echo "$out" | grep -q "unknown key 'mallory'" && ok "a key that is not in keys/release does not count" || bad "unknown key: $out"
mk revoked; echo "alice 2026-11-23 lost" > "$t/revoked/keys/REVOKED.txt"
out="$(run revoked)"; rc=$?; [ "$rc" -eq 0 ] && ! promoted revoked && echo "$out" | grep -q 'revoked' && ok "a revoked key does not count" || bad "revoked: $out"
mk two
out="$(run two RELEASE_MIN_SIGNATURES=2)"; rc=$?; [ "$rc" -eq 0 ] && ! promoted two && echo "$out" | grep -q 'waiting for engineer signatures (1 of 2)' && ok "too few signatures wait" || bad "min 2: $out"
esign "$t/two" bob; out="$(run two RELEASE_MIN_SIGNATURES=2)"; promoted two && ok "the second signature (a later commit) completes it" || bad "two signatures: $out"
mk nosig; rm "$t/nosig/ucb/kas/releases/"*.sig
out="$(run nosig)"; rc=$?; [ "$rc" -eq 0 ] && ! promoted nosig && ok "no signature yet: waits" || bad "no signature: $out"

# 5. Already released: the existing release is not touched.
mk exists; mkdir -p "$t/exists/root/release/testrel/0.0.1"; echo keep > "$t/exists/root/release/testrel/0.0.1/mark"
out="$(run exists)"; rc=$?; [ "$rc" -eq 0 ] && [ "$(cat "$t/exists/root/release/testrel/0.0.1/mark")" = keep ] && [ ! -e "$t/exists/root/release/testrel/0.0.1/PROMOTED" ] && ok "an existing release is left alone" || bad "existing release: $out"

# 6. Bad settings and names.
out="$(run good RELEASE_PROMOTE=sometimes)"; rc=$?; [ "$rc" -ne 0 ] && ok "a bad RELEASE_PROMOTE is refused" || bad "bad mode accepted"
mkdir -p "$t/good/root/staging/release/Bad/1.0.0"; out="$(run good)"; echo "$out" | grep -q 'not a release name' && ok "a staged name that is no release is ignored" || bad "bad name: $out"

# 7. cleanup-staging.sh: only a promoted release, only when old enough; the pull exclude line is written; -n changes nothing.
clean() { env RELEASE_ROOT="$t/good/root" "$@" "$here/cleanup-staging.sh" 2>&1; }
out="$(clean)"; [ -d "$t/good/root/staging/release/testrel/0.0.1" ] && ok "a young promoted copy is kept (7 days)" || bad "young copy removed: $out"
out="$(env RELEASE_ROOT="$t/good/root" RELEASE_STAGING_KEEP_DAYS=0 "$here/cleanup-staging.sh" -n 2>&1)"
[ -d "$t/good/root/staging/release/testrel/0.0.1" ] && echo "$out" | grep -q 'would remove' && ok "-n removes nothing" || bad "dry run: $out"
mk waiting2; rm "$t/waiting2/ucb/kas/releases/"*.sig; run waiting2 > /dev/null
out="$(env RELEASE_ROOT="$t/waiting2/root" RELEASE_STAGING_KEEP_DAYS=0 "$here/cleanup-staging.sh" 2>&1)"
[ -d "$t/waiting2/root/staging/release/testrel/0.0.1" ] && ok "an unpromoted staged release is never removed" || bad "unpromoted removed: $out"
out="$(clean RELEASE_STAGING_KEEP_DAYS=0)"
if [ ! -e "$t/good/root/staging/release/testrel/0.0.1" ] && [ -f "$t/good/root/release/testrel/0.0.1/SHA256SUMS" ] && grep -qx '/release/testrel/0.0.1/' "$t/good/root/release-done.txt"; then ok "an old promoted copy is removed, the release stays, the exclude line is written"; else bad "cleanup: $out"; fi

# 8. Before the first release there is no staging/release at all: nothing to do, no error. (cleanup-staging.sh the same)
mkdir -p "$t/empty/root" "$t/empty/ucb/kas/releases"
out="$(env RELEASE_ROOT="$t/empty/root" RELEASE_UCB_DIR="$t/empty/ucb" RELEASE_KEYS_DIR="$t/good/keys/release" COSIGN="$cosign" "$tool" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'nothing staged' && ok "no staging area yet: nothing to do, no error" || bad "empty root: $out"
out="$(env RELEASE_ROOT="$t/empty/root2" "$here/cleanup-staging.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "cleanup without a staging area is not an error" || bad "cleanup empty: $out"

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
