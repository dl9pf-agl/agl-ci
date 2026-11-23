#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Finish a release on the builder: put the signed files next to the images, verify everything, and rename the partial directory
# to the release directory. This is the last step of release.yml (job `finalize`).
#
#   release-finalize.sh
#
# Environment (all required):
#   RELEASE_STAGING     the release area of the cache directory, e.g. /srv/agl-cache/staging/release
#   RELEASE_BRANCH      the release line, e.g. vimba
#   RELEASE_VERSION     e.g. 22.0.2
#   RELEASE_RUN_ID      id of this release run: the partial directory must carry the same id (written by release-collect.sh)
#   RELEASE_SIGNED_DIR  the files made by the attest job, in the layout of the release directory (top-level SHA256SUMS and its
#                       bundle, the pins file, and per image: <target>.SHA256SUMS, <target>.provenance.json, <target>.slsa.intoto.bundle)
#
# Like release-collect.sh this runs as root in a container on the sidecar's Docker daemon, because only that sees the cache directory.
#
# Flow, in the order it runs:
#   1. check the environment and the state of the directories (partial exists and is ours; the release does not exist yet)
#   2. place the signed files in the partial directory   (a file that is already there must be byte-identical: the attest job runs
#                                                         on another machine and must not have changed what the build job wrote)
#   3. verify the top-level SHA256SUMS                    (it lists the per-image sums files, the bundles and the pins file)
#   4. verify every per-image sums file against the real image files   (this hashes the big files: the first time anybody does)
#   5. check that no file exists that nobody lists        (an unlisted file would be published unsigned)
#   6. rename <branch>/.<version>.partial to <branch>/<version>   (atomic; from now on the rsync daemon offers the release)
set -euo pipefail

die() { echo "release-finalize: $*" >&2; exit 1; }

# 1. Environment and state.
staging="${RELEASE_STAGING:?RELEASE_STAGING is not set}"
branch="${RELEASE_BRANCH:?RELEASE_BRANCH is not set}"
version="${RELEASE_VERSION:?RELEASE_VERSION is not set}"
run_id="${RELEASE_RUN_ID:?RELEASE_RUN_ID is not set}"
signed="${RELEASE_SIGNED_DIR:?RELEASE_SIGNED_DIR is not set}"
[[ "$branch" =~ ^[a-z]+$ ]] || die "bad RELEASE_BRANCH: '$branch'"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad RELEASE_VERSION: '$version'"
part="$staging/$branch/.$version.partial"
final="$staging/$branch/$version"
[ -d "$part" ] || die "no partial directory $part (did the build jobs run?)"
[ -d "$signed" ] || die "no directory of signed files $signed"
[ ! -e "$final" ] || die "release $branch/$version already exists in $staging (releases are immutable)"
# The partial directory must belong to this run; otherwise it is the leftover of another attempt and nothing here may touch it.
[ "$(cat "$part/.run-id" 2>/dev/null || true)" = "$run_id" ] || die "$part does not carry run id $run_id"
[ -f "$signed/SHA256SUMS" ] && [ -f "$signed/SHA256SUMS.bundle" ] || die "$signed lacks SHA256SUMS or SHA256SUMS.bundle"

# 2. Place the signed files. Everything in $signed is copied to the same relative path in the partial directory. A file that
#    exists there already (the per-image sums and statements, which the build jobs wrote and the attest job passed on) must be
#    identical; if the attest job's copy differs, something changed it on the way: stop.
n=0
while IFS= read -r -d '' f; do
  rel="${f#"$signed"/}"
  if [ -e "$part/$rel" ]; then
    cmp -s "$f" "$part/$rel" || die "'$rel' differs between the build jobs and the attest job"
  else
    mkdir -p "$(dirname "$part/$rel")"
    # Two statements, not `cp && mv`: set -e ignores a failure of the first command in an && list, and a failed copy must stop us.
    cp "$f" "$part/$rel.tmp"
    mv "$part/$rel.tmp" "$part/$rel"
    n=$((n + 1))
  fi
done < <(find "$signed" -type f -print0 | sort -z)
echo "release-finalize: placed $n signed files"

# 3. The top-level sums file: every file it lists must be there with the listed hash.
( cd "$part" && sha256sum -c --quiet SHA256SUMS ) || die "SHA256SUMS does not verify"
echo "release-finalize: SHA256SUMS verifies"

# 4. Every per-image sums file against the real files of its directory (images, kernel, boot files, statement).
images=0
while IFS= read -r -d '' sums; do
  ( cd "$(dirname "$sums")" && sha256sum -c --quiet "$(basename "$sums")" ) || die "$sums does not verify"
  images=$((images + 1))
done < <(find "$part" -type f -name '*.SHA256SUMS' -print0 | sort -z)
[ "$images" -gt 0 ] || die "no per-image sums file found in $part"
echo "release-finalize: $images per-image sums files verify"

# 5. Unlisted files. Every visible file must be listed by the top-level sums (as a path from the release root) or by the sums
#    file of its own directory; the top-level sums file and its bundle are the two exceptions. Hidden files (the run marker)
#    are never offered by the rsync daemon and are ignored. A leftover <name>.tmp from a failed copy shows up here.
listed="$(mktemp)"
awk '{ $1=""; sub(/^ +/, ""); print }' "$part/SHA256SUMS" | sed 's/^\*//' >> "$listed"          # paths relative to the release root
while IFS= read -r -d '' sums; do
  dir="${sums#"$part"/}"; dir="$(dirname "$dir")"
  awk '{ $1=""; sub(/^ +/, ""); print }' "$sums" | sed 's/^\*//' | sed "s#^#$dir/#" >> "$listed"  # prefixed with the directory of the sums file
done < <(find "$part" -type f -name '*.SHA256SUMS' -print0)
extra=0
# The search runs INSIDE the partial directory (its own name starts with a dot, a path filter on the full path would hide everything).
while IFS= read -r -d '' f; do
  rel="${f#./}"
  case "$rel" in SHA256SUMS|SHA256SUMS.bundle) continue ;; esac
  grep -qxF -- "$rel" "$listed" || { echo "release-finalize: not listed anywhere: $rel" >&2; extra=1; }
done < <(cd "$part" && find . -type f ! -name '.*' -print0 | sort -z)
[ "$extra" -eq 0 ] || die "the release directory holds files that no sums file lists"
echo "release-finalize: every file is listed"

# 6. Publish: the rename is atomic on one file system, so the rsync daemon sees either no release or the complete one.
mv "$part" "$final"
echo "release-finalize: $branch/$version is final: $final"
