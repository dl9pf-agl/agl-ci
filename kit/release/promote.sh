#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Promote verified releases on the DOWNLOAD SERVER: staging/release/<branch>/<version>/ -> release/<branch>/<version>/.
# Run from cron after the pull (kit/mirror/pull-sync.sh with AREAS="dl sstate git staging"), idempotent, one run at a time.
#
#   RELEASE_ROOT=/srv/mirror RELEASE_UCB_DIR=/srv/agl-ucb kit/release/promote.sh [<branch> <version>]
#
# With a branch and version only that release is looked at (manual mode: an engineer promotes by hand). Without: every staged one.
#
# Environment:
#   RELEASE_ROOT            the mirror tree holding staging/release and release (default /srv/mirror); both must be on ONE file system (the last step is a rename)
#   RELEASE_UCB_DIR         a read-only checkout of agl-ucb (the cron pulls it): the engineers' signatures are files there,
#                           kas/releases/<branch>_<version>.SHA256SUMS.<id>.sig, one commit each
#   RELEASE_KEYS_DIR        the engineers' public keys <id>.pub (default: keys/release of this checkout); REVOKED.txt next to it
#                           (RELEASE_REVOKED) lists "<id> <date> <reason>" lines: a key listed there never counts
#   RELEASE_PROMOTE         auto (default) or manual. manual: do every check and report, but do not promote
#   RELEASE_MIN_SIGNATURES  engineer signatures needed (default 1)
#   RELEASE_REPO            the repository whose tag the release workflow ran for (default dl9pf-agl/agl-ucb)
#   RELEASE_CI_VERIFY_ARGS  how to verify the CI signatures. Default: the keyless identity of agl-ci's release.yml at a pinned commit,
#                           issuer GitHub, repository and tag of the release. A test sets a public key here.
#   COSIGN                  cosign binary (default cosign)
#
# Flow per staged release, in the order it runs (the cheap checks first: a release that waits for its signature is not hashed again
# every few minutes):
#   1. names are plain, the directory is a real directory, the release does not exist yet (else: skipped, nothing is touched)
#   2. CI signature of SHA256SUMS (bundle) with the pinned identity           -> failure = error
#   3. engineer signatures: count those valid for a key that is not revoked   -> too few = "waiting", not an error
#   4. sha256sum -c of SHA256SUMS and of every per-image sums file; no symlink; no file that nobody lists   -> failure = error
#   5. every per-image attestation (bundle) verifies with the same identity    -> failure = error
#   6. auto: COPY the directory to a temp directory next to the release, add the engineers' signatures and a PROMOTED record, rename
#      into place (the rename is atomic). The staging copy stays: while it exists the pull does not fetch it again. Removing it is
#      the job of cleanup-staging.sh, later.
# Exit status: 0 if nothing is wrong (waiting and skipped are fine), 1 if any release failed a check (cron mails that).
set -euo pipefail
set -f   # the verify argument strings are split into words unquoted and contain [0-9a-f] (a glob)

here="$(cd "$(dirname "$0")" && pwd)"
root="${RELEASE_ROOT:-/srv/mirror}"
ucb="${RELEASE_UCB_DIR:-}"
keys="${RELEASE_KEYS_DIR:-$here/../../keys/release}"
revoked="${RELEASE_REVOKED:-$keys/../REVOKED.txt}"
mode="${RELEASE_PROMOTE:-auto}"
minsig="${RELEASE_MIN_SIGNATURES:-1}"
repo="${RELEASE_REPO:-dl9pf-agl/agl-ucb}"
cosign="${COSIGN:-cosign}"
URI="https://slsa.dev/provenance/v1"
owner="${repo%%/*}"
[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { echo "promote: bad RELEASE_REPO: $repo" >&2; exit 1; }
[[ "$mode" =~ ^(auto|manual)$ ]] || { echo "promote: RELEASE_PROMOTE must be auto or manual: $mode" >&2; exit 1; }
[[ "$minsig" =~ ^[0-9]+$ ]] && [ "$minsig" -ge 1 ] || { echo "promote: RELEASE_MIN_SIGNATURES must be a number >= 1" >&2; exit 1; }
[ -d "$ucb/kas/releases" ] || { echo "promote: RELEASE_UCB_DIR is not a checkout of agl-ucb: '$ucb'" >&2; exit 1; }
touch "$root/release-done.txt" 2>/dev/null || true
[ -d "$root/staging/release" ] || { echo "promote: no $root/staging/release (has the pull run?)" >&2; exit 1; }
command -v "$cosign" > /dev/null || { echo "promote: cosign not found ($cosign)" >&2; exit 1; }
mkdir -p "$root/release"

# One run at a time: a slow hash of a big release must not overlap the next cron start.
exec 9> "$root/.promote.lock"
flock -n 9 || { echo "promote: another run is active, leaving"; exit 0; }

# What the public sees at the top of staging.
[ -e "$root/staging/release/STAGING.txt" ] || printf '%s\n' "Files here are copied from the build host and NOT verified yet. Verified releases are under /release/." > "$root/staging/release/STAGING.txt"

# ci_args TAG: the arguments that make a CI signature mean "made by release.yml of agl-ci, for this repo and this tag".
ci_args() {
  if [ -n "${RELEASE_CI_VERIFY_ARGS+x}" ]; then printf '%s' "$RELEASE_CI_VERIFY_ARGS"; return; fi
  printf '%s' "--certificate-identity-regexp ^https://github.com/${owner}/agl-ci/\\.github/workflows/release\\.yml@[0-9a-f]{40}\$ --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-github-workflow-repository ${repo} --certificate-github-workflow-ref refs/tags/$1"
}

# check_one BRANCH VERSION: return 0 = promoted (or verified, in manual mode), 10 = waiting, 11 = skipped, 1 = failed.
check_one() {
  local branch="$1" version="$2" tag="${1}_${2}" stage final dir ok=0 sig id k args n=0 ids=""
  stage="$root/staging/release/$branch/$version"; final="$root/release/$branch/$version"
  # 1. names and state
  [[ "$branch" =~ ^[a-z]+$ && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "promote: $tag: not a release name, ignored"; return 11; }
  [ -d "$stage" ] && [ ! -L "$stage" ] || { echo "promote: $tag: not a real directory"; return 1; }
  if [ -e "$final" ]; then echo "promote: $tag: already released, skipped"; return 11; fi
  args="$(ci_args "$tag")"
  [ -f "$stage/SHA256SUMS" ] && [ -f "$stage/SHA256SUMS.bundle" ] || { echo "promote: $tag: SHA256SUMS or its bundle is missing (pull still running?)"; return 10; }
  # 2. CI signature
  # shellcheck disable=SC2086   # split into words on purpose
  ( cd "$stage" && "$cosign" verify-blob --bundle SHA256SUMS.bundle $args SHA256SUMS > /dev/null 2>&1 ) || { echo "promote: $tag: FAIL the CI signature of SHA256SUMS does not verify"; return 1; }
  # 3. engineer signatures
  while IFS= read -r -d '' sig; do
    id="${sig##*/}"; id="${id#"$tag".SHA256SUMS.}"; id="${id%.sig}"
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    [ -f "$keys/$id.pub" ] || { echo "promote: $tag: signature of unknown key '$id' ignored"; continue; }
    if [ -f "$revoked" ] && grep -q "^$id " "$revoked"; then echo "promote: $tag: key '$id' is revoked, signature ignored"; continue; fi
    case " $ids " in *" $id "*) continue ;; esac
    if "$cosign" verify-blob --key "$keys/$id.pub" --signature "$sig" --insecure-ignore-tlog=true "$stage/SHA256SUMS" > /dev/null 2>&1; then
      n=$((n + 1)); ids="$ids $id"; echo "promote: $tag: valid signature by $id"
    else echo "promote: $tag: signature file of '$id' does not verify, ignored"; fi
  done < <(find "$ucb/kas/releases" -maxdepth 1 -type f -name "$tag.SHA256SUMS.*.sig" -print0 | sort -z)
  if [ "$n" -lt "$minsig" ]; then echo "promote: $tag: CI signature ok, waiting for engineer signatures ($n of $minsig)"; return 10; fi
  # 4. hashes and file set
  [ -z "$(find "$stage" ! -type f ! -type d -print -quit)" ] || { echo "promote: $tag: FAIL the directory holds a symlink or special file"; return 1; }
  ( cd "$stage" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1 ) || { echo "promote: $tag: FAIL SHA256SUMS does not verify"; return 1; }
  local sums count=0 listed; listed="$(mktemp)"
  awk '{ $1=""; sub(/^ +/, ""); print }' "$stage/SHA256SUMS" | sed 's/^\*//' > "$listed"
  while IFS= read -r -d '' sums; do
    dir="${sums#"$stage"/}"; dir="$(dirname "$dir")"
    ( cd "$(dirname "$sums")" && sha256sum -c --quiet "$(basename "$sums")" > /dev/null 2>&1 ) || { echo "promote: $tag: FAIL $sums does not verify"; return 1; }
    awk '{ $1=""; sub(/^ +/, ""); print }' "$sums" | sed 's/^\*//' | sed "s#^#$dir/#" >> "$listed"
    count=$((count + 1))
    # 5. the attestation of this image (same directory, same name stem)
    local bundle="${sums%.SHA256SUMS}.slsa.intoto.bundle"
    # shellcheck disable=SC2086
    "$cosign" verify-blob-attestation --type "$URI" --bundle "$bundle" $args "$sums" > /dev/null 2>&1 || { echo "promote: $tag: FAIL attestation of $sums does not verify"; return 1; }
  done < <(find "$stage" -type f -name '*.SHA256SUMS' ! -path "$stage/SHA256SUMS" -print0 | sort -z)
  [ "$count" -gt 0 ] || { echo "promote: $tag: FAIL no per-image sums file"; return 1; }
  while IFS= read -r -d '' k; do
    k="${k#./}"; case "$k" in SHA256SUMS|SHA256SUMS.bundle) continue ;; esac
    grep -qxF -- "$k" "$listed" || { echo "promote: $tag: FAIL file that nobody lists: $k"; ok=1; }
  done < <(cd "$stage" && find . -type f -print0 | sort -z)
  [ "$ok" -eq 0 ] || return 1
  echo "promote: $tag: all checks pass ($count images, $n engineer signatures:$ids)"
  # 6. promote
  if [ "$mode" = manual ]; then echo "promote: $tag: manual mode, NOT promoted (run: promote.sh $branch $version)"; return 0; fi
  mkdir -p "$root/release/$branch"
  local tmp="$root/release/$branch/.$version.promoting"
  [ ! -e "$tmp" ] || { echo "promote: $tag: FAIL leftover $tmp from an earlier run; look at it, then move it away"; return 1; }
  cp -a "$stage" "$tmp" || { echo "promote: $tag: FAIL copy (disk full?); $tmp is left for a look"; return 1; }
  for id in $ids; do cp "$ucb/kas/releases/$tag.SHA256SUMS.$id.sig" "$tmp/SHA256SUMS.$id.sig"; done
  printf 'promoted %s by promote.sh, mode %s, engineer signatures:%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$ids" > "$tmp/PROMOTED"
  mv "$tmp" "$final" || { echo "promote: $tag: FAIL rename into place"; return 1; }
  echo "promote: $tag: PROMOTED to $final"
}

# Which releases: the one named on the command line, or every directory staging/release/<branch>/<version>.
list=()
if [ "$#" -eq 2 ]; then list=("$1 $2")
elif [ "$#" -eq 0 ]; then
  while IFS= read -r -d '' d; do list+=("$(basename "$(dirname "$d")") $(basename "$d")"); done < <(find "$root/staging/release" -mindepth 2 -maxdepth 2 -type d -print0 | sort -z)
else echo "usage: promote.sh [<branch> <version>]" >&2; exit 1; fi

failed=0
for item in "${list[@]}"; do
  # shellcheck disable=SC2086
  set -- $item
  rc=0; check_one "$1" "$2" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || [ "$rc" -eq 11 ] || failed=1
done
[ "${#list[@]}" -gt 0 ] || echo "promote: nothing staged"
exit "$failed"
