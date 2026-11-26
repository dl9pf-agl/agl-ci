#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove old build output from the staging areas of a BUILDER (the host that runs the builds): abandoned partial directories
# and finished nightlies and releases that the download server has had for long. Dry run by default; nothing is deleted without
# --apply. Run it as root, daily, from cron (kit/builder.cron); the cache directory is root-only (chapter 05).
#
#   kit/prune-builder.sh [--apply]      env CACHE_DIR (default /srv/agl-cache), PARTIAL_DAYS (default 4), KEEP_DAYS (default 7)
#
# What it removes, nothing else (every name is checked, no symlink is followed, one file system):
#   1. abandoned partial directories: $CACHE_DIR/nightly/.<date>.partial and $CACHE_DIR/staging/release/<branch>/.<version>.partial
#      that hold a .run-id file (our marker) and in which no file or directory changed for PARTIAL_DAYS days. A build job runs at
#      most two days, so a partial that quiet is the leftover of a failed run (nightly-finalize and release.yml never finished).
#   2. finished nightlies $CACHE_DIR/nightly/<YYYY-MM-DD-HHMM> and finished releases $CACHE_DIR/staging/release/<branch>/<x.y.z>
#      in which nothing changed for KEEP_DAYS days. By then the download server has pulled them (cron every 5 minutes) and keeps
#      its own copy (kit/release/cleanup-nightly.sh, cleanup-staging.sh). RISK: until the server has pulled a directory, the copy
#      here is the only one; if the pull does not work (it did not for the first nightly, 2026-11-25), look before KEEP_DAYS ends.
# Not touched: sstate/ and dl/ (kit/prune-cache.sh handles sstate by age; dl/ is never pruned), git/, anything else.
set -euo pipefail
cache="${CACHE_DIR:-/srv/agl-cache}"; partial_days="${PARTIAL_DAYS:-4}"; keep_days="${KEEP_DAYS:-7}"; apply=0
case "${1:-}" in "") ;; --apply) apply=1 ;; *) echo "usage: prune-builder.sh [--apply]" >&2; exit 2 ;; esac
[[ "$partial_days" =~ ^[0-9]+$ && "$keep_days" =~ ^[0-9]+$ ]] || { echo "PARTIAL_DAYS and KEEP_DAYS must be whole numbers" >&2; exit 2; }
[ -d "$cache" ] || { echo "$cache not found (run as root; CACHE_DIR=...)" >&2; exit 1; }

# quiet <dir> <days>: true when nothing in the directory (itself included) changed for that many days
quiet() { [ -z "$(find -P "$1" -xdev -mmin "-$(($2 * 1440))" -print -quit)" ]; }

n=0; bytes=0
# take <dir> <why>: say what happens to the directory, and do it with --apply
take() {
  local d="$1" size
  size="$(du -sk "$d" | cut -f1)"; bytes=$((bytes + size)); n=$((n + 1))
  if [ "$apply" = 1 ]; then rm -r --one-file-system -- "$d"; echo "removed: $d ($((size / 1024)) MiB, $2)"
  else echo "would remove: $d ($((size / 1024)) MiB, $2)"; fi
}

# 1. abandoned partial directories (nightly/ is one level deep, staging/release/<branch>/ two)
while IFS= read -r -d '' d; do
  [[ "$(basename "$d")" =~ ^\.[A-Za-z0-9.-]+\.partial$ ]] || continue
  [ -f "$d/.run-id" ] || continue
  quiet "$d" "$partial_days" && take "$d" "partial, quiet for $partial_days days"
done < <({ find -P "$cache/nightly" -xdev -mindepth 1 -maxdepth 1 -type d -name '.*.partial' -print0
           find -P "$cache/staging/release" -xdev -mindepth 2 -maxdepth 2 -type d -name '.*.partial' -print0; } 2>/dev/null)

# 2. finished nightlies and releases
while IFS= read -r -d '' d; do
  name="$(basename "$d")"
  case "$d" in
    "$cache/nightly/"*) [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || continue ;;
    *) [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$(basename "$(dirname "$d")")" =~ ^[a-z]+$ ]] || continue ;;
  esac
  quiet "$d" "$keep_days" && take "$d" "finished, quiet for $keep_days days"
done < <({ find -P "$cache/nightly" -xdev -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0
           find -P "$cache/staging/release" -xdev -mindepth 2 -maxdepth 2 -type d ! -name '.*' -print0; } 2>/dev/null)

[ "$apply" = 1 ] || echo "dry run: nothing is removed (add --apply)"
echo "prune-builder: $n directories, $((bytes / 1048576)) GiB"
echo "free space: $(df -h --output=avail "$cache" | tail -1 | tr -d ' ')"
