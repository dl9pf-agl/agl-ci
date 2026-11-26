#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Check and sign the small files of a release. This is the work of the `attest` job of release.yml, the only job that may sign.
#
#   release-attest.sh --small <dir> --pins <pins file> --matrix <json> --out <dir> --branch <branch> --version <version>
#
#   --small   the files the build jobs uploaded, in the layout <repo>/<machine>/<target>/<target>.SHA256SUMS and
#             <target>.provenance.json (the output of release-collect.sh)
#   --pins    kas/releases/pins_<branch>_<version>.yml of the release tag
#   --matrix  the matrix of the run, {"include":[{"repo":..., "machine":..., "target":..., ...}, ...]}: the images that must be there
#   --out     a NEW directory (must not exist) that receives the signed files, in the layout of the release directory
#
# Environment:
#   COSIGN              the cosign binary (default: cosign)
#   COSIGN_SIGN_ARGS    extra arguments for every signing call; EMPTY in the workflow, which means: keyless, with the GitHub identity
#                       of the job (the job has id-token: write). A test passes a throw-away key here.
#   COSIGN_VERIFY_ARGS  the arguments that make verification of what was just signed strict: in the workflow the certificate identity
#                       and issuer, in a test the public key. Verifying right after signing catches a wrong identity in the job
#                       instead of in the release.
#
# Flow, in the order it runs:
#   1. for each image of the matrix: check its kas statement (release-check.py), then attest the image's sums file
#         cosign attest-blob --type https://slsa.dev/provenance/v1 --predicate <the statement's predicate> <target>.SHA256SUMS
#      (the custom type URI keeps the kas predicate byte-identical; the short name slsaprovenance1 would rewrite it) and verify it
#   2. copy the pins file to the root of the output
#   3. write the top-level SHA256SUMS: every file of the output (per-image sums, statements, bundles, pins file) with its hash
#   4. sign the top-level file with cosign sign-blob and verify it
# The output is the release asset: kit/release/promote.sh unpacks it next to the images on the download server. Nothing here touches the big files: only hashes are signed.
set -euo pipefail
set -f   # no pathname expansion: the cosign argument strings are split into words unquoted and hold [0-9a-f] (a glob)

die() { echo "release-attest: $*" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
cosign="${COSIGN:-cosign}"
sign_args="${COSIGN_SIGN_ARGS:-}"
verify_args="${COSIGN_VERIFY_ARGS:-}"
PREDICATE_TYPE="https://slsa.dev/provenance/v1"

# Arguments.
small=""; pins=""; matrix=""; out=""; branch=""; version=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --small) small="${2:-}"; shift 2 ;;
    --pins) pins="${2:-}"; shift 2 ;;
    --matrix) matrix="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$small" ] || die "--small is not a directory: '$small'"
[ -f "$pins" ] || die "--pins is not a file: '$pins'"
[[ "$branch" =~ ^[a-z]+$ ]] || die "bad --branch: '$branch'"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad --version: '$version'"
[ -n "$out" ] && [ ! -e "$out" ] || die "--out must be a directory that does not exist yet: '$out'"
command -v "$cosign" >/dev/null || die "cosign not found ($cosign)"
command -v jq >/dev/null || die "jq not found"
# The images of this release, one "repo machine target" triple per line. Names go into paths: only plain names pass.
pairs="$(printf '%s' "$matrix" | jq -r '.include[] | "\(.repo) \(.machine) \(.target)"')" || die "--matrix is not a matrix JSON"
[ -n "$pairs" ] || die "the matrix has no image"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-attest.XXXXXX")"    # scratch space for the predicate files; kept

# (The commands inside the loop get /dev/null as stdin: the loop reads its pairs from stdin, and a command that also read stdin would eat them.)
# 1. Per image: check, attest, verify. The check refuses a statement that does not match the pins file BEFORE anything is signed.
n=0
while read -r repo machine target; do
  [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$repo" != null && "$machine" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "bad names in the matrix: '$repo' '$machine' '$target'"
  rel="$repo/$machine/$target"
  sums="$small/$rel/$target.SHA256SUMS"
  stmt="$small/$rel/$target.provenance.json"
  [ -f "$sums" ] && [ -f "$stmt" ] || die "files of $target on $machine are missing in $small/$rel (did its build job upload them?)"
  echo "release-attest: $target on $machine: checking the statement"
  python3 "$here/release-check.py" --statement "$stmt" --pins "$pins" --sums "$sums" --target "$target" < /dev/null || die "$target on $machine: the statement does not match the pins file; nothing is signed"
  # Copies into the output: the signed files are the ones the build jobs wrote (promote.sh checks them against the signed sums again).
  mkdir -p "$out/$rel"
  cp "$sums" "$stmt" "$out/$rel/"
  # The predicate is the part of the statement that says HOW the image was built; the sums file is the subject (its hash is what is signed).
  jq .predicate "$stmt" > "$work/$repo.$machine.$target.predicate.json"
  bundle="$out/$rel/$target.slsa.intoto.bundle"
  # shellcheck disable=SC2086   # the argument strings are meant to be split into words
  "$cosign" attest-blob --yes --type "$PREDICATE_TYPE" --predicate "$work/$repo.$machine.$target.predicate.json" --bundle "$bundle" $sign_args "$out/$rel/$target.SHA256SUMS" < /dev/null > /dev/null
  # shellcheck disable=SC2086
  "$cosign" verify-blob-attestation --type "$PREDICATE_TYPE" --bundle "$bundle" $verify_args "$out/$rel/$target.SHA256SUMS" < /dev/null > /dev/null \
    || die "$target on $machine: the attestation just made does not verify"
  n=$((n + 1))
done <<< "$pairs"

# 2. The pins file of the release, at the root, under the name that belongs to the tag.
cp "$pins" "$out/pins_${branch}_${version}.yml"

# 3. The top-level sums file: every file of the output except itself and its bundle, paths relative to the release root, sorted.
( cd "$out" && find . -type f ! -name 'SHA256SUMS' ! -name 'SHA256SUMS.bundle' -print | sed 's#^\./##' | LC_ALL=C sort \
    | xargs -d '\n' sha256sum -- > SHA256SUMS )

# 4. Sign the top-level file and verify it. One signature covers everything that is listed, which includes the other signatures.
# shellcheck disable=SC2086
( cd "$out" && "$cosign" sign-blob --yes --bundle SHA256SUMS.bundle $sign_args SHA256SUMS > /dev/null )
# shellcheck disable=SC2086
( cd "$out" && "$cosign" verify-blob --bundle SHA256SUMS.bundle $verify_args SHA256SUMS > /dev/null ) || die "the signature of SHA256SUMS just made does not verify"
echo "release-attest: $n images attested, $(wc -l < "$out/SHA256SUMS") files in the top-level SHA256SUMS, signed: $out"
