#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Collect the files of ONE nightly image into the nightly staging directory of the builder and make them visible at once: the
# download-server pull (kit/release/run.sh nightly, every minute) offers each image as soon as its own collect step is done, not
# when the whole run is. Same pattern as release-collect.sh but simpler: no signing; the directory key is a date-time instead of
# a branch/version.
#
#   nightly-collect.sh --machine <machine> --target <target> --repo <repo>
#
# Environment (all required unless a default is named):
#   AGL_TREE          the build tree of the job; the deploy output is $AGL_TREE/build/tmp/deploy/images/<machine>
#   NIGHTLY_STAGING   the nightly area of the cache directory, e.g. /srv/agl-cache/nightly (created if missing)
#   NIGHTLY_DATE      the date-time key of this run, e.g. 2026-11-26-0300 (one value, computed once per workflow run and
#                     passed to every matrix job, so all images of one run land in the same folder)
#   NIGHTLY_COMMIT    the commit of the repository that owns the image (goes into build.toml)
#   NIGHTLY_RUN_URL   the web address of this run, for build.toml (default: empty)
#   NIGHTLY_BUILDER   the builder container image (name@digest), for build.toml (default: empty)
#   NIGHTLY_RUN_ID    id of this nightly run (default: GITHUB_RUN_ID, else "local"); all images of one run must carry it
#
# The layout (public): <date>/<repo>/<machine>/<target>/ holds everything of one image: its files, the kernel and boot files,
# the scanner reports, build.toml (repo, commit, run, builder) and <target>.SHA256SUMS. The folder appears in one step, complete. A consumer
# that reads it through the download server (a LAVA job) waits until the sums file is there AND verifies, and retries otherwise.
# The run as a whole is complete when <date>/COMPLETE exists (nightly-finalize.sh, after every build job of the run).
#
# Flow, in the order it runs:
#   1. check the arguments and the environment
#   2. guard: a complete nightly, the directory of ANOTHER run, or an image that is already there: refuse (nothing is deleted)
#   3. select the files: the image's own plain-named files and the machine's kernel/boot files
#   4. copy them into the hidden work directory .<date>.partial (links resolved), add report-trowl/ and report-vulnscout/ if the
#      scanners wrote them, then build.toml and the sums file
#   5. publish: move the finished folder to its public place (one rename on one file system: atomic, nothing half written shows)
set -euo pipefail

die() { echo "nightly-collect: $*" >&2; exit 1; }

# 1. Arguments and environment.
machine=""; target=""; repo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --machine) machine="${2:-}"; shift 2 ;;
    --target)  target="${2:-}";  shift 2 ;;
    --repo)    repo="${2:-}";    shift 2 ;;
    *) die "unknown argument: $1 (usage: nightly-collect.sh --machine <machine> --target <target> --repo <repo>)" ;;
  esac
done
tree="${AGL_TREE:?AGL_TREE is not set}"
staging="${NIGHTLY_STAGING:?NIGHTLY_STAGING is not set}"
date="${NIGHTLY_DATE:?NIGHTLY_DATE is not set}"
commit="${NIGHTLY_COMMIT:?NIGHTLY_COMMIT is not set}"
run_url="${NIGHTLY_RUN_URL:-}"
builder="${NIGHTLY_BUILDER:-}"
run_id="${NIGHTLY_RUN_ID:-${GITHUB_RUN_ID:-local}}"
# Names go into paths and glob patterns below: only plain names are accepted.
[[ "$machine" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --machine: '$machine'"
[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --target: '$target'"
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --repo: '$repo'"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || die "bad NIGHTLY_DATE (want YYYY-MM-DD-HHMM): '$date'"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "bad NIGHTLY_COMMIT (want 40 hex characters): '$commit'"
[[ "$run_url" =~ ^[A-Za-z0-9:/._-]*$ ]] || die "bad NIGHTLY_RUN_URL: '$run_url'"
[[ "$builder" =~ ^[A-Za-z0-9:@/._-]*$ ]] || die "bad NIGHTLY_BUILDER: '$builder'"

deploy="$tree/build/tmp/deploy/images/$machine"   # what bitbake deployed for this machine in this job
part="$staging/.$date.partial"                    # the hidden work directory; the rsync pull never offers dotfiles
work="$part/$repo/$machine/$target"
final="$staging/$date"                            # the public directory of this run
pub="$final/$repo/$machine/$target"               # the public folder of this image
[ -d "$deploy" ] || die "no deploy directory $deploy (did the build run?)"

# 2. Guard. A directory that belongs to another run means two runs picked the same minute (or one failed halfway); mixing their
#    files would be wrong, so stop and let a person decide.
[ ! -e "$final/COMPLETE" ] || die "nightly $date is already complete in $staging (pick a new NIGHTLY_DATE)"
for d in "$final" "$part"; do
  if [ -e "$d/.run-id" ] && [ "$(cat "$d/.run-id")" != "$run_id" ]; then
    die "$d belongs to run $(cat "$d/.run-id"), not $run_id: an earlier attempt is incomplete; remove it by hand if it is dead"
  fi
done
[ ! -e "$pub" ] || die "$target for $machine ($repo) is already in the nightly $date"

# 3. Select the files (same patterns as release-collect.sh).
own_pattern="${target}-${machine}.*"
shared_patterns=("*Image-${machine}.bin" "*Image" "*.efi" "*.efi.stub" "*.dtb")
declare -A seen=()
names=()
select_files() {
  local kind="$1" pat f; shift
  for pat in "$@"; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$deploy/$f" ] || continue
      [ -z "${seen[$f]:-}" ] || continue
      seen[$f]="$kind"; names+=("$f")
    done < <(cd "$deploy" && compgen -G "$pat" || true)
  done
}
select_files own "$own_pattern"
[ "${#names[@]}" -gt 0 ] || die "no file $own_pattern in $deploy: is '$target' the image that was built for '$machine'?"
select_files shared "${shared_patterns[@]}"

# 4. Copy into the work directory. First record this run's id in both directories (the guard above compares against it).
mkdir -p "$work" "$final"
echo "$run_id" > "$part/.run-id"
echo "$run_id" > "$final/.run-id"
for f in "${names[@]}"; do
  cp -L --preserve=timestamps "$deploy/$f" "$work/$f"
done

# Scanner report directories, if the scanner wrote one: report-trowl/ (written by bitbake itself: the class trowl of meta-trowl, AGL_TROWL=1) and
# report-vulnscout/ (the vulnscout step of the workflow, AGL_VULNSCOUT=1). Whole directories,
# copied recursively. Marked seen so the "not included" report below does not list them as skipped.
for report in report-trowl report-vulnscout; do
  if [ -d "$deploy/$report" ]; then
    mkdir -p "$work/$report"
    cp -a "$deploy/$report/." "$work/$report/"
    seen[$report]=scanner
  fi
done

# What was built, for whoever tests the image later; then the sums of every file in the folder (the sums file not itself).
printf 'repo = "%s"\ncommit = "%s"\nrun = "%s"\nbuilder = "%s"\n' "$repo" "$commit" "$run_url" "$builder" > "$work/build.toml"
( cd "$work" && find . -type f ! -name "$target.SHA256SUMS" -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum -- ) > "$part/sums.tmp"
mv "$part/sums.tmp" "$work/$target.SHA256SUMS"
total="$(du -sh "$work" | cut -f1)"

# 5. Publish.
mkdir -p "$(dirname "$pub")"
mv "$work" "$pub"

echo "nightly-collect: $target on $machine ($repo): ${#names[@]} files, $total, published: $pub"
others=()
for f in "$deploy"/*; do
  [ -z "${seen[${f##*/}]:-}" ] || continue
  others+=("${f##*/}")
done
echo "nightly-collect: not included: ${#others[@]} entries (timestamped copies, files of other images, directories)"
