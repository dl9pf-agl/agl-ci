#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Point RELEASE_ROOT/nightly/latest at the newest nightly that has at least one published image. Not necessarily complete or
# green: the newest one that is known. A run that is still building, or had a failed image, shows only the images it has; whoever
# needs a particular run uses its dated address. Run by kit/release/run.sh after every nightly pull and after the cleanup.
#
#   RELEASE_ROOT   the published tree (default /srv/agl-permanent)
#
# Flow, in the order it runs:
#   1. find the newest nightly/<date> that holds a sums file (an image folder is complete when its sums file is there)
#   2. none: remove an old link. Otherwise replace the link in one rename, so that it never is missing in between
set -euo pipefail
dir="${RELEASE_ROOT:-/srv/agl-permanent}/nightly"
[ -d "$dir" ] || exit 0
link="$dir/latest"
if [ -e "$link" ] && [ ! -L "$link" ]; then echo "latest-nightly: $link is not a link, left alone" >&2; exit 1; fi

# 1. the names are YYYY-MM-DD-HHMM, so the order of the glob is the order in time: the last match wins
newest=""
for d in "$dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  [ -z "$(find "$d" -mindepth 4 -maxdepth 4 -type f -name '*.SHA256SUMS' -print -quit)" ] || newest="${d##*/}"
done

# 2. the link is relative: it works on the host and inside the web server's container
if [ -z "$newest" ]; then rm -f "$link"; exit 0; fi
[ "$(readlink "$link" 2>/dev/null || true)" != "$newest" ] || exit 0
ln -sfn "$newest" "$dir/.latest.tmp"
mv -T "$dir/.latest.tmp" "$link"
echo "latest-nightly: latest -> $newest"
