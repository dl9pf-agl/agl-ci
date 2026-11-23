#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove the staging copy of releases that were promoted long enough ago. Run daily from cron on the DOWNLOAD SERVER.
#
#   RELEASE_ROOT=/srv/mirror kit/release/cleanup-staging.sh [-n]      -n: only say what would be removed
#
#   RELEASE_ROOT              the mirror tree (default /srv/mirror)
#   RELEASE_STAGING_KEEP_DAYS days to keep the staging copy after promotion (default 7); 0 = remove at once
#
# Flow: for each staging/release/<branch>/<version> whose release/<branch>/<version>/PROMOTED exists and is older than the limit:
#   1. remove the staging directory
#   2. add "/release/<branch>/<version>/" to $RELEASE_ROOT/release-done.txt, the exclude file of the pull (agl-release.cron):
#      the build host still offers the release, and without that line the next pull would copy it into staging again.
# A staged release that is NOT promoted is never touched. The build host's own copy is cleaned up there, by hand.
set -euo pipefail
root="${RELEASE_ROOT:-/srv/mirror}"; days="${RELEASE_STAGING_KEEP_DAYS:-7}"
[[ "$days" =~ ^[0-9]+$ ]] || { echo "cleanup-staging: RELEASE_STAGING_KEEP_DAYS must be a number" >&2; exit 1; }
dry=0; [ "${1:-}" != -n ] || dry=1
[ -d "$root/staging/release" ] || { echo "cleanup-staging: no $root/staging/release" >&2; exit 1; }
n=0
while IFS= read -r -d '' d; do
  version="$(basename "$d")"; branch="$(basename "$(dirname "$d")")"
  [[ "$branch" =~ ^[a-z]+$ && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  [ ! -L "$d" ] || continue
  mark="$root/release/$branch/$version/PROMOTED"
  [ -f "$mark" ] || continue                                                   # not promoted: keep
  [ -n "$(find "$mark" -mmin "+$((days * 1440))" -print)" ] || [ "$days" -eq 0 ] || continue   # too young: keep
  if [ "$dry" -eq 1 ]; then echo "cleanup-staging: would remove $d"; continue; fi
  echo "/release/$branch/$version/" >> "$root/release-done.txt"                  # first the exclude line: a crash here must not re-fetch
  rm -rf -- "$d"
  echo "cleanup-staging: removed $d"
  n=$((n + 1))
done < <(find "$root/staging/release" -mindepth 2 -maxdepth 2 -type d -print0 | sort -z)
echo "cleanup-staging: $n staging copies removed"
