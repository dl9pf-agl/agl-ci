#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove nightly directories older than a few days from the download server. Run daily from cron on the DOWNLOAD SERVER.
# Same idea as cleanup-staging.sh, simpler: a nightly is never "promoted", so age is the only test (the directory's own mtime,
# set when the pull finished writing it - the builder's own copy of a nightly is cleaned up there, by hand, same as a staged
# release that was never promoted).
#
#   RELEASE_ROOT=/srv/agl-permanent kit/release/cleanup-nightly.sh [-n]      -n: only say what would be removed
#
#   RELEASE_ROOT         the mirror tree (default /srv/agl-permanent)
#   NIGHTLY_KEEP_DAYS     days to keep a nightly directory (default 7); 0 = remove at once
#
# Flow: for each nightly/<date> older than the limit:
#   1. add "/nightly/<date>/" to $RELEASE_ROOT/nightly-done.txt, the exclude file of the pull (server.cron): without
#      that line the next pull would copy it back from the builder (its own copy is not cleaned up by this script)
#   2. remove the directory
set -euo pipefail
root="${RELEASE_ROOT:-/srv/agl-permanent}"; days="${NIGHTLY_KEEP_DAYS:-7}"
[[ "$days" =~ ^[0-9]+$ ]] || { echo "cleanup-nightly: NIGHTLY_KEEP_DAYS must be a number" >&2; exit 1; }
dry=0; [ "${1:-}" != -n ] || dry=1
[ -d "$root/nightly" ] || { echo "cleanup-nightly: no nightly yet, nothing to do"; exit 0; }   # before the first nightly pull
n=0
while IFS= read -r -d '' d; do
  date="$(basename "$d")"
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || continue
  [ ! -L "$d" ] || continue
  [ -n "$(find "$d" -maxdepth 0 -mmin "+$((days * 1440))" -print)" ] || [ "$days" -eq 0 ] || continue   # too young: keep
  if [ "$dry" -eq 1 ]; then echo "cleanup-nightly: would remove $d"; continue; fi
  echo "/nightly/$date/" >> "$root/nightly-done.txt"   # first the exclude line: a crash here must not re-fetch
  rm -rf -- "$d"
  echo "cleanup-nightly: removed $d"
  n=$((n + 1))
done < <(find "$root/nightly" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
echo "cleanup-nightly: $n nightly directories removed"
