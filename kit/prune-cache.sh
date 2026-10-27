#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Keep the shared sstate cache (or a mirror's sstate tree) from growing without end: delete sstate files that nobody has used
# for a long time. Dry run by default; nothing is deleted without --apply. Run it as root (the cache is root-only, chapter 05).
#
#   kit/prune-cache.sh [--apply] [--sstate-days N] [--mtime]      env CACHE_DIR (default /srv/agl-cache)
#
#   --sstate-days N  delete sstate files not used for N days (default 60). sstate can always be rebuilt.
#   --mtime          use the modification time instead of the access time. Needed when the file system is mounted noatime
#                    (the script refuses to guess: with noatime a used file looks unused).
#
# dl/ is NEVER pruned, there is no option for it: the downloads are the premirror that lets an old build be rebuilt during an
# outage of its upstream (chapter 15), and they grow slowly. Binary releases are not handled here either (artifact retention,
# chapter 15 / M2).
#
# Safe by construction: only regular files below sstate/ (no symlinks followed, one file system), never hashserv.db* or
# LAST_SYNC, never a file changed in the last day (it may be in use), empty directories are removed afterwards. An old hash
# equivalence that points at a deleted object is a benign miss (chapter 15), so pruning by age is allowed.
set -euo pipefail
cache="${CACHE_DIR:-/srv/agl-cache}"; apply=0; sstate_days=60; use=atime
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --sstate-days) sstate_days="${2:?--sstate-days needs a number}"; shift 2 ;;
    --mtime) use=mtime; shift ;;
    *) echo "unknown argument: $1 (see the header of this script)" >&2; exit 2 ;;
  esac
done
[[ "$sstate_days" =~ ^[0-9]+$ ]] || { echo "--sstate-days must be a whole number" >&2; exit 2; }
[ -d "$cache/sstate" ] || { echo "$cache/sstate not found (run as root; CACHE_DIR=...)" >&2; exit 1; }
if [ "$use" = atime ] && findmnt -no OPTIONS -T "$cache" 2>/dev/null | grep -qw noatime; then
  echo "$cache is mounted noatime: access times say nothing. Use --mtime, or mount with relatime." >&2; exit 1
fi
old=(-type f ! -name 'hashserv.db*' ! -name LAST_SYNC "-$use" "+$sstate_days" -mmin +1440)
list="$(find -P "$cache/sstate" -xdev "${old[@]}" -printf '%s\n')"
n="$(printf '%s' "$list" | grep -c . || true)"; size="$(printf '%s' "$list" | awk '{s+=$1} END {printf "%.1f", s/1073741824}')"
[ "$apply" = 1 ] || echo "dry run: nothing is deleted (add --apply)"
echo "sstate: $n files not used for more than $sstate_days days, $size GiB"
if [ "$apply" = 1 ] && [ "$n" -gt 0 ]; then
  find -P "$cache/sstate" -xdev "${old[@]}" -delete
  find -P "$cache/sstate" -xdev -mindepth 2 -type d -empty -delete
  echo "sstate: deleted"
fi
echo "dl: never pruned"
echo "free space: $(df -h --output=avail "$cache" | tail -1 | tr -d ' ')"
