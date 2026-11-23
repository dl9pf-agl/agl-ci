#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Collect the files of ONE release image into the release staging directory of the builder.
#
#   release-collect.sh --machine <machine> --target <target>
#
# Environment (all required unless a default is named):
#   AGL_TREE          the build tree of the job (agl-ucb checkout); the deploy output is $AGL_TREE/build/tmp/deploy/images/<machine>
#                     and the kas provenance statement is $AGL_TREE/build/attestation/kas-build.provenance.json
#   RELEASE_STAGING   the release area of the cache directory, e.g. /srv/agl-cache/staging/release (created if missing)
#   RELEASE_BRANCH    the release line, e.g. vimba (lower case letters)
#   RELEASE_VERSION   e.g. 22.0.2
#   RELEASE_RUN_ID    id of this release run (default: GITHUB_RUN_ID, else "local"); all images of one release must carry the same id
#   RELEASE_SMALL_DIR where to put the small files for the upload to the attest job (default: $AGL_TREE/build/release-small)
#
# Why this is a separate script: the runner container cannot enter the cache directory (root:root 0700), so build.sh runs this
# script inside a container on the sidecar's Docker daemon (as root, cache directory mounted). The script itself is plain file work
# and is tested on its own (release-collect_test.sh).
#
# Flow, in the order it runs:
#   1. check the arguments and the environment (names end up in paths, so they are strict)
#   2. guard the release directory           (final directory exists: refuse; partial directory of another run: refuse)
#   3. select the files                      (the image's own plain-named files, plus the machine's shared kernel and boot files)
#   4. copy them into the partial directory  (links resolved; a shared file that already exists must be byte-identical)
#   5. write <target>.SHA256SUMS             (hashes of everything of this image, including its kas statement)
#   6. copy the two small files to RELEASE_SMALL_DIR (the sums and the statement, for the artifact upload)
# The partial directory is renamed to the final name later, by the finalize job, after the signatures are in place.
set -euo pipefail

die() { echo "release-collect: $*" >&2; exit 1; }

# 1. Arguments and environment.
machine=""; target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --machine) machine="${2:-}"; shift 2 ;;
    --target)  target="${2:-}";  shift 2 ;;
    *) die "unknown argument: $1 (usage: release-collect.sh --machine <machine> --target <target>)" ;;
  esac
done
tree="${AGL_TREE:?AGL_TREE is not set}"
staging="${RELEASE_STAGING:?RELEASE_STAGING is not set}"
branch="${RELEASE_BRANCH:?RELEASE_BRANCH is not set}"
version="${RELEASE_VERSION:?RELEASE_VERSION is not set}"
run_id="${RELEASE_RUN_ID:-${GITHUB_RUN_ID:-local}}"
small="${RELEASE_SMALL_DIR:-$tree/build/release-small}"
# Names go into paths and into glob patterns below: only plain names are accepted.
[[ "$machine" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --machine: '$machine'"
[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --target: '$target'"
[[ "$branch" =~ ^[a-z]+$ ]] || die "bad RELEASE_BRANCH: '$branch'"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad RELEASE_VERSION: '$version'"

deploy="$tree/build/tmp/deploy/images/$machine"        # what bitbake deployed for this machine in this job
stmt="$tree/build/attestation/kas-build.provenance.json" # written by kas build --provenance
final="$staging/$branch/$version"                       # the finished release directory (exists only after finalize)
part="$staging/$branch/.$version.partial"               # where the jobs of one run collect; hidden: the rsync daemon never offers dotfiles
dest="$part/$machine/deploy/images/$machine"            # the public layout: <machine>/deploy/images/<machine>/
[ -d "$deploy" ] || die "no deploy directory $deploy (did the build run?)"
[ -f "$stmt" ] || die "no kas statement $stmt (build with --provenance)"

# 2. Guards. A release is immutable: a finished directory of this version means this release exists already. A partial directory
#    that belongs to another run (different run id) means an earlier attempt failed halfway; mixing two runs would put old and new
#    files side by side, so stop and let a person decide (nothing is deleted automatically).
#    These are only checks; nothing is created before the files are selected (step 3), so a refused call leaves nothing behind.
[ ! -e "$final" ] || die "release $branch/$version already exists in $staging (releases are immutable; use a new version)"
if [ -e "$part/.run-id" ] && [ "$(cat "$part/.run-id")" != "$run_id" ]; then
  die "$part belongs to run $(cat "$part/.run-id"), not $run_id: an earlier attempt is incomplete; remove it by hand if it is dead"
fi

# 3. Select the files. All patterns are relative to the deploy directory.
#    own     <target>-<machine>.*   the image's files with their plain names (ext4.xz, wic.zst, manifest, spdx.json, ...). The
#                                   dot after the machine name keeps out the timestamped copies (<target>-<machine>-2026....)
#    shared  kernel and boot files that every image of the machine uses; they are written once per machine, and every image's
#            sums file lists them. This list is the FIRST GUESS for the file list (decision 4 of the design, to be revisited);
#            files that match nothing are reported below so that a missing kind of file is noticed.
own_pattern="${target}-${machine}.*"
shared_patterns=("*Image-${machine}.bin" "*Image" "*.efi" "*.efi.stub" "*.dtb")
declare -A seen=()      # name -> "own" or "shared": a file that matches two patterns is taken once
names=()                # the selected file names, own files first
select_files() {        # select_files <kind> <pattern>...
  local kind="$1" pat f; shift
  for pat in "$@"; do
    # compgen -G lists the matches of a glob (one per line); no match is not an error here
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$deploy/$f" ] || continue          # skips directories and links to nowhere; a link to a file passes
      [ -z "${seen[$f]:-}" ] || continue
      seen[$f]="$kind"; names+=("$f")
    done < <(cd "$deploy" && compgen -G "$pat" || true)
  done
}
select_files own "$own_pattern"
[ "${#names[@]}" -gt 0 ] || die "no file $own_pattern in $deploy: is '$target' the image that was built for '$machine'?"
select_files shared "${shared_patterns[@]}"

# 4. Copy. First create the directories and record this run's id in the hidden marker (the guard of step 2 compares against it).
#    cp -L follows the plain-name links, so the release holds the real files under the plain names. A file is first copied to
#    <name>.tmp and then renamed, so that no half-written file ever has its final name. A shared file that is already there (copied
#    by another image of the same machine) must be byte-identical, otherwise two images disagree about the kernel: fail.
mkdir -p "$dest"
echo "$run_id" > "$part/.run-id"
for f in "${names[@]}"; do
  if [ -e "$dest/$f" ]; then
    cmp -s "$deploy/$f" "$dest/$f" || die "'$f' is already in the release with different content (two images of $machine disagree)"
    continue
  fi
  cp -L --preserve=timestamps "$deploy/$f" "$dest/$f.tmp"
  mv "$dest/$f.tmp" "$dest/$f"
done
# The kas statement of this image, under a name that belongs to the target (several images share one directory).
cp "$stmt" "$dest/$target.provenance.json"
names+=("$target.provenance.json")

# 5. The sums file of this image: one line per file, paths relative to this directory, so `sha256sum -c <target>.SHA256SUMS` works
#    from there. It lists the statement too, which ties the statement to the files. It does not list itself.
[ ! -e "$dest/$target.SHA256SUMS" ] || die "$target was already collected for $machine in this release"
( cd "$dest" && printf '%s\n' "${names[@]}" | LC_ALL=C sort | xargs -d '\n' sha256sum -- ) > "$dest/$target.SHA256SUMS.tmp"
mv "$dest/$target.SHA256SUMS.tmp" "$dest/$target.SHA256SUMS"

# 6. The small files for the attest job: the sums and the statement, in the same relative layout. About 30 KB per image.
mkdir -p "$small/$machine/deploy/images/$machine"
cp "$dest/$target.SHA256SUMS" "$dest/$target.provenance.json" "$small/$machine/deploy/images/$machine/"

# Report: what went in, and what was left out (so that a kind of file that should be in the release does not go missing unseen).
total="$(cd "$dest" && du -ch -- "${names[@]}" | tail -n 1 | cut -f1)"
echo "release-collect: $target on $machine: ${#names[@]} files, $total, into $part"
others=()
for f in "$deploy"/*; do
  [ -z "${seen[${f##*/}]:-}" ] || continue      # selected files are in $seen; everything else is reported
  others+=("${f##*/}")
done
echo "release-collect: not included: ${#others[@]} entries (timestamped copies, files of other images, directories)"
for f in "${others[@]:0:12}"; do echo "release-collect:   $f"; done
[ ! -d "$tree/build/tmp/deploy/sdk" ] || echo "release-collect: NOTE: $tree/build/tmp/deploy/sdk exists; the SDK is not collected yet"
