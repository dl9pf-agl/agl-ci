#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Collect the files of ONE nightly image into the nightly staging directory of the builder, same pattern as
# release-collect.sh but simpler: no signing, no SHA256SUMS (nothing downstream verifies a nightly), and the directory key
# is a date-time instead of a branch/version, with the repo name added because several repos' nightly runs share one
# NIGHTLY_STAGING tree (each at its own cron time, landing in its own dated folder; same-minute collisions across repos are
# kept apart by the repo subdirectory).
#
#   nightly-collect.sh --machine <machine> --target <target> --repo <repo>
#
# Environment (all required unless a default is named):
#   AGL_TREE          the build tree of the job; the deploy output is $AGL_TREE/build/tmp/deploy/images/<machine>
#   NIGHTLY_STAGING   the nightly area of the cache directory, e.g. /srv/agl-cache/nightly (created if missing)
#   NIGHTLY_DATE      the date-time key of this run, e.g. 2026-11-26-0300 (one value, computed once per workflow run and
#                     passed to every matrix job, so all images of one run land in the same folder)
#   NIGHTLY_RUN_ID    id of this nightly run (default: GITHUB_RUN_ID, else "local"); all images of one run must carry it
#
# Flow, in the order it runs:
#   1. check the arguments and the environment
#   2. guard the nightly directory (partial directory of another run: refuse; nothing is deleted automatically)
#   3. select the files: the image's own plain-named files, the machine's shared kernel/boot files, and report-trowl/ if
#      the trowl class of meta-trowl (AGL_TROWL=1) wrote one - a whole directory, copied recursively, not matched by the glob
#   4. copy them into the partial directory (links resolved; a shared file that already exists must be byte-identical)
# The partial directory is renamed to the final name later, by nightly-finalize.sh, once every job of the run is done.
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
run_id="${NIGHTLY_RUN_ID:-${GITHUB_RUN_ID:-local}}"
# Names go into paths and glob patterns below: only plain names are accepted.
[[ "$machine" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --machine: '$machine'"
[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --target: '$target'"
[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --repo: '$repo'"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || die "bad NIGHTLY_DATE (want YYYY-MM-DD-HHMM): '$date'"

deploy="$tree/build/tmp/deploy/images/$machine"   # what bitbake deployed for this machine in this job
part="$staging/.$date.partial"                    # where the jobs of one run collect; hidden: the rsync pull never offers dotfiles
dest="$part/$repo/$machine/deploy/images/$machine" # the public layout: <repo>/<machine>/deploy/images/<machine>/
final="$staging/$date"
[ -d "$deploy" ] || die "no deploy directory $deploy (did the build run?)"

# 2. Guard. A partial directory that belongs to another run means an earlier attempt failed halfway or two runs picked the
#    same minute; either way, mixing their files would be wrong, so stop and let a person decide.
[ ! -e "$final" ] || die "nightly $date already exists in $staging (pick a new NIGHTLY_DATE, or the finalize already ran)"
if [ -e "$part/.run-id" ] && [ "$(cat "$part/.run-id")" != "$run_id" ]; then
  die "$part belongs to run $(cat "$part/.run-id"), not $run_id: an earlier attempt is incomplete; remove it by hand if it is dead"
fi

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

# 4. Copy. First create the directories and record this run's id in the hidden marker (the guard above compares against it).
mkdir -p "$dest"
echo "$run_id" > "$part/.run-id"
for f in "${names[@]}"; do
  if [ -e "$dest/$f" ]; then
    cmp -s "$deploy/$f" "$dest/$f" || die "'$f' is already in the nightly with different content (two images of $machine disagree)"
    continue
  fi
  cp -L --preserve=timestamps "$deploy/$f" "$dest/$f.tmp"
  mv "$dest/$f.tmp" "$dest/$f"
done

# Scanner report directories, if the scanner wrote one: report-trowl/ (written by bitbake itself: the class trowl of meta-trowl, AGL_TROWL=1) and
# report-vulnscout/ (the vulnscout step of the workflow, AGL_VULNSCOUT=1). Whole directories,
# copied recursively. Marked seen so the "not included" report below does not list them as skipped.
for report in report-trowl report-vulnscout; do
  if [ -d "$deploy/$report" ]; then
    mkdir -p "$dest/$report"
    cp -a "$deploy/$report/." "$dest/$report/"
    seen[$report]=scanner
  fi
done

total="$(cd "$dest" && du -ch -- "${names[@]}" | tail -n 1 | cut -f1)"
echo "nightly-collect: $target on $machine ($repo): ${#names[@]} files, $total, into $part"
others=()
for f in "$deploy"/*; do
  [ -z "${seen[${f##*/}]:-}" ] || continue
  others+=("${f##*/}")
done
echo "nightly-collect: not included: ${#others[@]} entries (timestamped copies, files of other images, directories)"
